import AppKit
import CmuxNextDesign
import CmuxNextSettings
import WebKit

/// `debug.window_snapshot`: one of this app's own windows as the window
/// server composited it (vibrancy, glass and Metal as on screen; an app may
/// read its own windows without Screen Recording permission), else drawn
/// by AppKit (`NSWindow.renderSnapshot`, where Metal content and blur
/// differ from the screen). `method` says which (plans/cmux-next/windows.md).
///
/// Params: `window` (a main window id, or any window's number from
/// `debug.window_list`: popovers, panels and sheets too), or `kind`
/// (a `WindowKind` raw value: `main`, `settings`, `debugSettings`,
/// `appStore`, `onboarding`, ...);
/// default the key window, else the active main window. `path` is the PNG
/// to write (default a file in the temporary directory). Returns `path`,
/// `width`, `height` (pixels), `kind`, `window_number` and `method`
/// (`composited` or `appkit`).
enum DebugWindowSnapshot {
    private struct WebViewTarget {
        let view: WKWebView
        let frame: CGRect
        let order: Int
    }

    private struct CompositeResult {
        let image: CGImage
        let composited: Int
        let hiddenComposited: Int
    }

    static func capture(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard let window = window(params, services: services) else { return .object(["error": .string("no such window")]) }
        let kind = kind(of: window, services: services)
        let path = params["path"]?.stringValue.map { ($0 as NSString).expandingTildeInPath }
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("cmux-window-\(kind)-\(window.windowNumber).png")
        do {
            let (size, method) = try window.writeSnapshot(to: URL(fileURLWithPath: path))
            return .object([
                "path": .string(path), "width": JSONValue(Int(size.width)), "height": JSONValue(Int(size.height)),
                "kind": .string(kind), "window_number": JSONValue(window.windowNumber), "method": .string(method.rawValue),
            ])
        } catch {
            return .object(["error": .string("snapshot failed: \(error.localizedDescription)")])
        }
    }

    /// Captures the window and paints each visible WebKit page over the window
    /// image. The window server and AppKit snapshots omit WebKit's remote
    /// content because it is rendered by the WebContent process.
    @MainActor
    static func captureAsync(_ params: [String: JSONValue], services: AppServices) async -> JSONValue {
        guard let window = window(params, services: services) else { return .object(["error": .string("no such window")]) }
        let kind = kind(of: window, services: services)
        let path = params["path"]?.stringValue.map { ($0 as NSString).expandingTildeInPath }
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("cmux-window-\(kind)-\(window.windowNumber).png")
        do {
            let targets = webViewTargets(in: window)
            let visibleTargets = targets.filter { isVisible($0.view, in: window) }
            // AppKit drawing supplies the chrome and backdrop without stale
            // remote WebKit layers. Hide every WebKit view while drawing the
            // native base, including parked and hidden tabs. Only views that
            // are visible at both selection and draw time are composited back.
            // AppKit cannot draw WebKit's remote content, so hide WebViews only
            // when at least one visible page will be restored below. If every
            // attached page is parked/hidden, retain the window-server snapshot
            // so native Metal content is not replaced by an AppKit-only render.
            let base = visibleTargets.isEmpty
                ? try baseImage(for: window)
                : try nativeBaseImage(for: window, hiding: targets.map(\.view))
            var images: [(WebViewTarget, CGImage)] = []
            var failed = 0
            for target in visibleTargets.sorted(by: { $0.order < $1.order }) {
                do {
                    let image = try await target.view.takeSnapshot(configuration: nil)
                    var proposedRect = NSRect.zero
                    guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
                        failed += 1
                        continue
                    }
                    images.append((target, cgImage))
                } catch {
                    failed += 1
                }
            }
            guard failed == 0 else {
                return .object([
                    "error": .string("one or more visible WebViews failed to snapshot"),
                    "kind": .string(kind),
                    "window_number": JSONValue(window.windowNumber),
                    "webviews": JSONValue(targets.count),
                    "webviews_visible": JSONValue(visibleTargets.count),
                    "webviews_failed": JSONValue(failed),
                ])
            }
            let composite = composite(base: base.image, window: window, webViews: images)
            guard let compositeResult = composite, compositeResult.hiddenComposited == 0 else {
                return .object([
                    "error": .string("hidden WebView would have been composited"),
                    "kind": .string(kind),
                    "window_number": JSONValue(window.windowNumber),
                    "webviews": JSONValue(targets.count),
                    "webviews_visible": JSONValue(visibleTargets.count),
                    "webviews_hidden_composited": JSONValue(composite?.hiddenComposited ?? 1),
                ])
            }
            let output = compositeResult.image
            let rep = NSBitmapImageRep(cgImage: output)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return .object([
                "path": .string(path), "width": JSONValue(rep.pixelsWide), "height": JSONValue(rep.pixelsHigh),
                "kind": .string(kind), "window_number": JSONValue(window.windowNumber), "method": .string(base.method.rawValue),
                "webviews": JSONValue(targets.count), "webviews_visible": JSONValue(visibleTargets.count),
                "webviews_hidden": JSONValue(targets.count - visibleTargets.count),
                "webviews_composited": JSONValue(compositeResult.composited),
                "webviews_hidden_composited": JSONValue(compositeResult.hiddenComposited),
                "webviews_failed": JSONValue(failed),
            ])
        } catch {
            return .object(["error": .string("snapshot failed: \(error.localizedDescription)")])
        }
    }

    private static func baseImage(for window: NSWindow) throws -> (image: CGImage, method: WindowSnapshotMethod) {
        if let image = window.compositedSnapshot() {
            return (image, .composited)
        }
        if let rep = window.renderSnapshot(), let image = rep.cgImage {
            return (image, .appkit)
        }
        throw CocoaError(.fileWriteUnknown)
    }

    private static func appKitBaseImage(for window: NSWindow) throws -> (image: CGImage, method: WindowSnapshotMethod) {
        guard let rep = window.renderSnapshot(), let image = rep.cgImage else { throw CocoaError(.fileWriteUnknown) }
        return (image, .appkit)
    }

    private static func nativeBaseImage(for window: NSWindow, hiding webViews: [WKWebView]) throws -> (image: CGImage, method: WindowSnapshotMethod) {
        let states = webViews.map { ($0, $0.isHidden, $0.layer?.isHidden ?? false) }
        for (webView, _, _) in states {
            webView.isHidden = true
            webView.layer?.isHidden = true
        }
        defer {
            for (webView, isHidden, layerHidden) in states {
                webView.isHidden = isHidden
                webView.layer?.isHidden = layerHidden
            }
        }
        window.contentView?.displayIfNeeded()
        return try appKitBaseImage(for: window)
    }

    private static func webViewTargets(in window: NSWindow) -> [WebViewTarget] {
        guard let root = window.contentView,
              let frameView = window.contentView?.superview ?? window.contentView else { return [] }
        var result: [WebViewTarget] = []
        var order = 0
        func visit(_ view: NSView) {
            if let webView = view as? WKWebView, webView.window === window {
                let frame = webView.convert(webView.bounds, to: frameView)
                if frame.width > 0, frame.height > 0 {
                    result.append(WebViewTarget(view: webView, frame: frame, order: order))
                    order += 1
                }
            }
            for child in view.subviews { visit(child) }
        }
        visit(root)
        return result
    }

    private static func isVisible(_ webView: WKWebView, in window: NSWindow) -> Bool {
        window.isVisible && webView.window === window && !webView.isHidden && !webView.isHiddenOrHasHiddenAncestor
            && effectiveAlpha(of: webView) > 0
    }

    private static func effectiveAlpha(of view: NSView) -> CGFloat {
        var alpha: CGFloat = 1
        var current: NSView? = view
        while let candidate = current {
            alpha *= candidate.alphaValue
            if alpha <= 0 { return 0 }
            current = candidate.superview
        }
        return alpha
    }

    private static func composite(base: CGImage, window: NSWindow, webViews: [(WebViewTarget, CGImage)]) -> CompositeResult? {
        guard let frameView = window.contentView?.superview ?? window.contentView,
              frameView.bounds.width > 0, frameView.bounds.height > 0 else { return nil }
        let width = base.width
        let height = base.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scaleX = CGFloat(width) / frameView.bounds.width
        let scaleY = CGFloat(height) / frameView.bounds.height
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        var hiddenComposited = 0
        var composited = 0
        for (target, image) in webViews.sorted(by: { $0.0.order < $1.0.order }) {
            guard isVisible(target.view, in: window) else {
                hiddenComposited += 1
                continue
            }
            let viewRect = target.frame
            let bottom = frameView.isFlipped ? frameView.bounds.height - viewRect.maxY : viewRect.minY
            let rect = CGRect(x: viewRect.minX * scaleX, y: bottom * scaleY,
                              width: viewRect.width * scaleX, height: viewRect.height * scaleY)
            guard rect.width > 0, rect.height > 0 else { continue }
            context.interpolationQuality = .high
            context.draw(image, in: rect)
            composited += 1
        }
        guard let image = context.makeImage() else { return nil }
        return CompositeResult(image: image, composited: composited, hiddenComposited: hiddenComposited)
    }

    /// The window `params` names.
    static func window(_ params: [String: JSONValue], services: AppServices) -> NSWindow? {
        let windows = NSApp.windows
        if let id = params["window"]?.stringValue ?? params["window"]?.intValue.map(String.init) {
            if let main = services.windows.controller(for: id)?.window { return main }
            return windows.first { String($0.windowNumber) == id }
        }
        if let kind = params["kind"]?.stringValue {
            if kind == "main" { return services.windows.active?.window }
            return windows.first { $0.isVisible && Self.kind(of: $0, services: services) == kind }
        }
        return NSApp.keyWindow ?? services.windows.active?.window
    }

    /// The window's kind as `debug.window_list` names it.
    static func kind(of window: NSWindow, services: AppServices) -> String {
        DebugWindowList.kind(of: window, services: services)
    }
}

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
            let webViews = visibleWebViews(in: window)
            // AppKit drawing supplies the chrome and backdrop without stale
            // remote WebKit layers. Hide the live views while drawing the
            // native base so the page snapshots below fill each rectangle
            // exactly once.
            let base = webViews.isEmpty ? try baseImage(for: window) : try nativeBaseImage(for: window, hiding: webViews)
            var images: [(WKWebView, CGImage)] = []
            var failed = 0
            for webView in webViews {
                do {
                    let image = try await webView.takeSnapshot(configuration: nil)
                    var proposedRect = NSRect.zero
                    guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
                        failed += 1
                        continue
                    }
                    images.append((webView, cgImage))
                } catch {
                    failed += 1
                }
            }
            let output = composite(base: base.image, window: window, webViews: images) ?? base.image
            let rep = NSBitmapImageRep(cgImage: output)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return .object([
                "path": .string(path), "width": JSONValue(rep.pixelsWide), "height": JSONValue(rep.pixelsHigh),
                "kind": .string(kind), "window_number": JSONValue(window.windowNumber), "method": .string(base.method.rawValue),
                "webviews": JSONValue(webViews.count), "webviews_composited": JSONValue(images.count),
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

    /// The web views of `window` that are on screen: the ones the snapshot
    /// paints over the native base image.
    static func visibleWebViews(in window: NSWindow) -> [WKWebView] {
        guard let root = window.contentView else { return [] }
        var result: [WKWebView] = []
        func visit(_ view: NSView) {
            if let webView = view as? WKWebView,
               webView.window === window,
               !webView.isHiddenOrHasHiddenAncestor,
               webView.alphaValue > 0,
               webView.bounds.width > 0,
               webView.bounds.height > 0 {
                result.append(webView)
            }
            for child in view.subviews { visit(child) }
        }
        visit(root)
        return result
    }

    private static func composite(base: CGImage, window: NSWindow, webViews: [(WKWebView, CGImage)]) -> CGImage? {
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
        for (webView, image) in webViews {
            let viewRect = webView.convert(webView.bounds, to: frameView)
            let bottom = frameView.isFlipped ? frameView.bounds.height - viewRect.maxY : viewRect.minY
            let rect = CGRect(x: viewRect.minX * scaleX, y: bottom * scaleY,
                              width: viewRect.width * scaleX, height: viewRect.height * scaleY)
            guard rect.width > 0, rect.height > 0 else { continue }
            context.interpolationQuality = .high
            context.draw(image, in: rect)
        }
        return context.makeImage()
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

import AppKit
import CmuxNextBrowser
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
/// `width`, `height` (pixels), `kind`, `window_number`, `method`
/// (`composited` or `appkit`) and `child_windows` (how many visible child
/// windows the window has). Child windows are composited by the window
/// server over the window: a Chromium page draws into its own child window,
/// and overlay panels sit above content. The async verb also paints each
/// engine's own image of every shown page (`webviews`, `chromium_pages`,
/// with `_composited` and `_failed` counts), since the window server
/// leaves out page content other processes draw unless the app has the
/// Screen Recording grant. `webviews: false` skips the page images (the
/// window server's image alone).
///
/// The refusal HUD (`RefusalHUD`) is a Liquid Glass pill that fades in and
/// hides after 1.8 s, so its pixels are not a reliable assertion: a capture
/// may land before the fade or after the hide. Every reply therefore carries
/// `refusal_hud`: the message the HUD shows now (null when hidden) and
/// `refusal_hud_count`, the messages shown so far. Check those instead of
/// looking for the pill in the PNG.
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
                "child_windows": JSONValue(method == .composited ? window.visibleChildWindows.count : 0),
                "refusal_hud": hudMessage(services), "refusal_hud_count": JSONValue(services.refusalHUD.shownCount),
            ])
        } catch {
            return .object(["error": .string("snapshot failed: \(error.localizedDescription)")])
        }
    }

    /// Captures the window and paints each visible page over the window
    /// image, in screen order: the window (with its page child windows), the
    /// WebKit pages, the Chromium pages, then the overlay panels above
    /// content. The window server and AppKit snapshots omit WebKit's remote
    /// content (the WebContent process draws it) and, without the Screen
    /// Recording grant, Chromium's (its GPU process draws into the page's
    /// child window), so each engine's own page image is painted instead:
    /// `WKWebView.takeSnapshot` and Chromium's `Page.captureScreenshot`
    /// (`BrowserTab.snapshot`), which need no grant and work for a
    /// background, non-key window.
    @MainActor
    static func captureAsync(_ params: [String: JSONValue], services: AppServices) async -> JSONValue {
        if params["webviews"]?.boolValue == false { return capture(params, services: services) }
        guard let window = window(params, services: services) else { return .object(["error": .string("no such window")]) }
        let kind = kind(of: window, services: services)
        let path = params["path"]?.stringValue.map { ($0 as NSString).expandingTildeInPath }
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("cmux-window-\(kind)-\(window.windowNumber).png")
        do {
            let webViews = visibleWebViews(in: window)
            // AppKit drawing supplies the chrome and backdrop without stale
            // remote WebKit layers. Hide the live views while drawing the
            // native base so the page snapshots below fill each rectangle
            // exactly once. The overlay panels go on top at the end, so the
            // composited base has only the page windows.
            let base = webViews.isEmpty ? try baseImage(for: window) : try nativeBaseImage(for: window, hiding: webViews)
            var layers: [Layer] = []
            if base.method == .appkit, let pageWindows = window.childWindowsSnapshot(includeChild: WindowOverlayHost.isPageWindow) {
                layers.append(.window(pageWindows))
            }
            var failed = 0
            for webView in webViews {
                do {
                    let image = try await webView.takeSnapshot(configuration: nil)
                    var proposedRect = NSRect.zero
                    guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
                        failed += 1
                        continue
                    }
                    layers.append(.page(cgImage, webView.convert(webView.bounds, to: nil)))
                } catch {
                    failed += 1
                }
            }
            let pages = chromiumPages(in: window, services: services)
            var pagesFailed = 0
            for (page, rect) in pages {
                do {
                    layers.append(.page(try await page.snapshot(), rect))
                } catch {
                    pagesFailed += 1
                }
            }
            if let panels = window.childWindowsSnapshot(includeChild: { !WindowOverlayHost.isPageWindow($0) }) {
                layers.append(.window(panels))
            }
            let output = composite(base: base.image, window: window, layers: layers) ?? base.image
            let rep = NSBitmapImageRep(cgImage: output)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return .object([
                "path": .string(path), "width": JSONValue(rep.pixelsWide), "height": JSONValue(rep.pixelsHigh),
                "kind": .string(kind), "window_number": JSONValue(window.windowNumber), "method": .string(base.method.rawValue),
                "webviews": JSONValue(webViews.count), "webviews_composited": JSONValue(webViews.count - failed),
                "webviews_failed": JSONValue(failed), "child_windows": JSONValue(window.visibleChildWindows.count),
                "chromium_pages": JSONValue(pages.count), "chromium_pages_composited": JSONValue(pages.count - pagesFailed),
                "chromium_pages_failed": JSONValue(pagesFailed),
                "refusal_hud": hudMessage(services), "refusal_hud_count": JSONValue(services.refusalHUD.shownCount),
            ])
        } catch {
            return .object(["error": .string("snapshot failed: \(error.localizedDescription)")])
        }
    }

    /// The refusal HUD's message while it shows, else null.
    static func hudMessage(_ services: AppServices) -> JSONValue {
        services.refusalHUD.message.map(JSONValue.string) ?? .null
    }

    /// What `composite` paints over the base image, bottom first.
    private enum Layer {
        /// A page image filling a rectangle in window coordinates.
        case page(CGImage, NSRect)
        /// A window server image of child windows, the size of the window.
        case window(CGImage)
    }

    /// The Chromium pages shown in `window`'s panes, with the page area in
    /// window coordinates (beside a docked DevTools, which is not painted).
    @MainActor
    static func chromiumPages(in window: NSWindow, services: AppServices) -> [(CEFTab, NSRect)] {
        guard let controller = services.windows.controllers.first(where: { $0.window === window }) else { return [] }
        var result: [(CEFTab, NSRect)] = []
        for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
            guard case .browser(let entry)? = pane.currentContent, let page = entry.tab as? CEFTab,
                  page.contentView.window === window, !page.contentView.isHiddenOrHasHiddenAncestor else { continue }
            let rect = page.devToolsDiagnosticFrames.map { window.convertFromScreen($0.page) }
                ?? page.contentView.convert(page.contentView.bounds, to: nil)
            guard rect.width > 0, rect.height > 0 else { continue }
            result.append((page, rect))
        }
        return result
    }

    private static func baseImage(for window: NSWindow) throws -> (image: CGImage, method: WindowSnapshotMethod) {
        if let image = window.compositedSnapshot(includeChild: WindowOverlayHost.isPageWindow) {
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
            // A hidden or transparent view hides its whole subtree on screen
            // (layer opacity multiplies down the tree). The new tab spare
            // waits under the alpha-0 NewTabSpareParking: never paint it.
            guard !view.isHidden, view.alphaValue > 0 else { return }
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

    private static func composite(base: CGImage, window: NSWindow, layers: [Layer]) -> CGImage? {
        let size = window.frame.size
        guard !layers.isEmpty, size.width > 0, size.height > 0 else { return nil }
        let width = base.width
        let height = base.height
        // sRGB, the space the written PNG is tagged with.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scaleX = CGFloat(width) / size.width
        let scaleY = CGFloat(height) / size.height
        let whole = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(base, in: whole)
        context.interpolationQuality = .high
        for layer in layers {
            switch layer {
            case .page(let image, let rect):
                // Window coordinates and the bitmap both have a bottom-left origin.
                let pixels = CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY, width: rect.width * scaleX, height: rect.height * scaleY)
                if pixels.width > 0, pixels.height > 0 { context.draw(image, in: pixels) }
            case .window(let image):
                context.draw(image, in: whole)
            }
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

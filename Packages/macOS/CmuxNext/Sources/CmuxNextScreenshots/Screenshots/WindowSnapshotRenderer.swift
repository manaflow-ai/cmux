package import AppKit
import CmuxNextDesign
package import CmuxNextSettings
package import WebKit

/// Captures a window with the window server when available, falling back to AppKit drawing. The server
/// includes glass and Metal as drawn and can capture the app’s own windows without Screen Recording.
/// The report gives the PNG path, pixel width and height, window kind and window_number, and the
/// capture method (composited or appkit). The child_windows and child_windows_failed counts describe
/// visible children included and omitted. The floating_windows count covers this app's menus, popovers
/// and cards over the window. Other titled windows at the same level and their children stay out of the image.
/// Page capture also reports the number of WebKit and Chromium pages captured and failed, and docked
/// DevTools without a page image.
@MainActor
package struct WindowSnapshotRenderer {
    package init() {}
    package static func captureNative(window: NSWindow, kind: String, path: String) async -> JSONValue {
        do {
            // The window with its child windows and the app's menus, cards and popovers over it,
            // composited together as on screen; else AppKit drawing (no child windows).
            // Read before the capture's await: a sheet may close meanwhile.
            let children = window.visibleChildWindows.count
            let together = await window.compositedImageWithOverlays()
            let snapshot = try together.map { (image: $0.image, method: WindowSnapshotMethod.composited) } ?? window.snapshotImage()
            let output = snapshot.image
            try await NSWindow.encodeSnapshotPNG(output, to: URL(fileURLWithPath: path))
            return .object([
                "path": .string(path), "width": JSONValue(output.width), "height": JSONValue(output.height),
                "kind": .string(kind), "window_number": JSONValue(window.windowNumber), "method": .string(snapshot.method.rawValue),
                "child_windows": JSONValue(snapshot.method == .composited ? children : 0),
                "child_windows_failed": JSONValue(snapshot.method == .composited ? 0 : children),
                "floating_windows": JSONValue(together?.floating ?? 0),
            ])
        } catch {
            return .object(["error": .string("snapshot failed: \(error.localizedDescription)")])
        }
    }

    /// Captures the window and paints each visible page over the window
    /// image, in screen order: the window (with its child windows and the
    /// app's menus open over it), the WebKit pages, the Chromium pages, then
    /// the overlay panels and menus again where they cover a page. The base is
    /// the window server's image whenever it gives one: it is the window as on
    /// screen, WebKit pages and overlays included (WebKit pages are layers of
    /// this window), so no WebKit image is painted over it. AppKit drawing
    /// is only the fallback (no window server image, a host without a lit
    /// display): it leaves out WebKit's remote content, so each page's own
    /// image is painted there, and it drops Liquid Glass with the views
    /// around it (a sidebar holding a glass card came out empty, cx-ddjj).
    /// Without the Screen Recording grant both leave out Chromium's page
    /// (its GPU process draws into the page's child window), so Chromium's
    /// own image (`Page.captureScreenshot`, `BrowserTab.snapshot`) is
    /// painted; WebKit's `takeSnapshot` and that need no grant and work for
    /// a background, non-key window.
    package static func capturePages(window: NSWindow, kind: String, path: String, includeChromiumPages: Bool,
                                     isSuspended: @MainActor (WKWebView) -> Bool,
                                     pageLayers: @MainActor (_ skip: Bool) async -> (layers: [WindowImageLayer], pages: Int, failed: Int)) async -> JSONValue {
        do {
            let webViews = visibleWebViews(in: window)
            // The window server's image first: the window as on screen, WebKit
            // pages, child windows and the app's menus and popovers over it
            // composited together, so glass over the window blurs it. Only
            // without it, AppKit drawing with the live web views hidden, so the
            // page snapshots below fill each rectangle exactly once, and the
            // overlay panels painted on top at the end.
            // The overlays are cut from the composite in the same capture, before the page images' awaits: a popover
            // that opened meanwhile is not in the composite, and its cut would be the window under it.
            // The child windows each layer brings, read with the capture's plan, so the result counts
            // only the ones the image includes (none from a missing layer).
            let children = window.visibleChildWindows
            let together = await window.compositedImageWithOverlays(cuttingOverlays: { !WindowOverlayHost.isPageWindow($0) })
            let base = try together.map { (image: $0.image, method: WindowSnapshotMethod.composited) }
                ?? window.renderSnapshot(hiding: webViews)
            let overlays = together?.overlays
            var layers: [WindowImageLayer] = []
            let pageChildren = children.filter(WindowOverlayHost.isPageWindow).count
            var childrenIncluded = base.method == .composited ? children.count : 0
            if base.method == .appkit, let pageWindows = await window.childWindowsImage(includeChild: WindowOverlayHost.isPageWindow) {
                layers.append(.window(pageWindows))
                childrenIncluded += pageChildren
            }
            var failed = 0
            for webView in webViews where base.method == .appkit && !isSuspended(webView) { // WebKit raises on a frozen page's snapshot
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
            let pages = await pageLayers(base.method == .composited && !includeChromiumPages)
            layers += pages.layers
            let pagesFailed = pages.failed
            var floatingCount = together?.floating ?? 0
            if base.method == .composited {
                // A Chromium page image covered the panels, popovers and menus over its page:
                // their pixels come back from the window server's composite, the page under them.
                if !layers.isEmpty, let overlays {
                    layers.append(.window(overlays))
                }
            } else {
                if let panels = await window.childWindowsImage(includeChild: { !WindowOverlayHost.isPageWindow($0) }) {
                    layers.append(.window(panels))
                    childrenIncluded += children.count - pageChildren
                }
                // Menus, and cards or popovers not attached to the window, go on top.
                let floating = await window.floatingWindowsImage()
                if let floating { layers.append(.window(floating.image)) }
                floatingCount = floating?.count ?? 0
            }
            let painted = await WindowImageLayer.compositedOffMain(base: base.image, windowSize: window.frame.size, layers: layers)
            let output = painted ?? base.image
            // The window server captures, the overlay mask, the paint, the PNG compression and
            // the file write run off the main actor; main reads only AppKit state.
            try await NSWindow.encodeSnapshotPNG(output, to: URL(fileURLWithPath: path))
            return .object([
                "path": .string(path), "width": JSONValue(output.width), "height": JSONValue(output.height),
                "kind": .string(kind), "window_number": JSONValue(window.windowNumber), "method": .string(base.method.rawValue),
                "webviews": JSONValue(webViews.count), "webviews_composited": JSONValue(webViews.count - failed),
                "webviews_failed": JSONValue(failed), "child_windows": JSONValue(childrenIncluded),
                "child_windows_failed": JSONValue(children.count - childrenIncluded),
                "floating_windows": JSONValue(base.method == .composited || painted != nil ? floatingCount : 0),
                "chromium_pages": JSONValue(pages.pages),
                "chromium_pages_composited": JSONValue(pages.pages - pagesFailed),
                "chromium_pages_failed": JSONValue(pagesFailed),
                "devtools_not_captured": JSONValue(layers.count(where: { if case .notCaptured = $0 { true } else { false } }) - pagesFailed),
            ])
        } catch {
            return .object(["error": .string("snapshot failed: \(error.localizedDescription)")])
        }
    }

    /// The web views of `window` that are on screen: the ones the snapshot
    /// paints over the native base image.
    private static func visibleWebViews(in window: NSWindow) -> [WKWebView] {
        guard let root = window.contentView else { return [] }
        var result: [WKWebView] = []
        func visit(_ view: NSView) {
            // A hidden or transparent view hides its whole subtree on screen
            // (layer opacity multiplies down the tree). The new tab spare
            // waits under the alpha-0 PageOffscreenParking: never paint it.
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
}

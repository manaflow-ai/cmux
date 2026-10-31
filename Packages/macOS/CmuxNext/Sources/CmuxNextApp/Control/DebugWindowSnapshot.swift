import AppKit
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import WebKit
import CmuxNextScreenshots

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
/// (`composited` or `appkit`), `child_windows` (how many of the window's
/// visible child windows the image includes) and `child_windows_failed`
/// (how many it leaves out because the window server gave no image of
/// them; AppKit drawing never includes a child window). Child windows are
/// composited by the window server with the window: a Chromium page draws
/// into its own child window, and overlay panels and popovers sit above content.
/// `floating_windows` counts the app's other windows the window server shows
/// above the window and over it, cut to its frame: an open
/// context menu (not in AppKit's window list), a hover card or popover that is
/// not its child; another of the app's titled windows in front at the same
/// level, with its own child windows and sheets, is left out. The window, its
/// child windows and those windows are one window server composite
/// (``NSWindow/compositedSnapshotWithOverlays()``), so a glass popover or menu
/// blurs the window under it, as on screen (composited apart, it came out grey). The
/// async verb also paints each engine's own image of every shown page
/// (`webviews`, `chromium_pages`, with `_composited` and `_failed` counts),
/// since the window server
/// leaves out page content other processes draw unless the app has the
/// Screen Recording grant. `webviews: false` skips the page images (the
/// window server's image alone).
///
/// A refusal (`RefusalHUD`) shows as a toast that fades in and ends after
/// 4 s (later while the pointer is on it), so its pixels are not a reliable
/// assertion: a capture may land before the fade or after it ends. Every
/// reply therefore carries `refusal_hud`: the message the refusal toast
/// shows now (null when none) and `refusal_hud_count`, the messages shown so
/// far. Check those (or `debug.toast`) instead of looking for the toast in
/// the PNG.
enum DebugWindowSnapshot {
    /// How long `debug.window_snapshot` may take, instead of the 2 s control-plane deadline. The
    /// capture runs on the main actor and takes about 50 ms once it runs, but on a capture mini
    /// that also runs builds and tests, or while the app is still launching, the wait for the
    /// main actor alone passed 2 s: the snapshot timed out and the capture had no still. Its
    /// callers wait 10 to 90 s (pr-capture's driver 30 s).
    static let deadline: Duration = .seconds(30)

    /// The control route, `debug.window_snapshot`, with its own ``deadline``.
    static func controlMethod(services: AppServices) -> ControlMethod {
        .async("debug.window_snapshot") { [weak services] call in
            guard let services = await MainActor.run(body: { services }) else { return .null }
            return await captureAsync(call.params, services: services)
        }.withDeadline(.fixed(deadline))
    }

    @MainActor
    static func capture(_ params: [String: JSONValue], services: AppServices) async -> JSONValue {
        guard let window = window(params, services: services) else { return .object(["error": .string("no such window")]) }
        let kind = kind(of: window, services: services)
        let path = params["path"]?.stringValue.map { ($0 as NSString).expandingTildeInPath }
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("cmux-window-\(kind)-\(window.windowNumber).png")
        do {
            // The window with its child windows and the app's menus, cards and popovers over it,
            // composited together as on screen; else AppKit drawing (no child windows).
            let together = window.compositedSnapshotWithOverlays()
            let snapshot = try together.map { (image: $0.image, method: WindowSnapshotMethod.composited) } ?? window.snapshotImage()
            // Read before the encode's await: a sheet may close meanwhile.
            let children = window.visibleChildWindows.count
            let output = snapshot.image
            try await NSWindow.encodeSnapshotPNG(output, to: URL(fileURLWithPath: path))
            return .object([
                "path": .string(path), "width": JSONValue(output.width), "height": JSONValue(output.height),
                "kind": .string(kind), "window_number": JSONValue(window.windowNumber), "method": .string(snapshot.method.rawValue),
                "child_windows": JSONValue(snapshot.method == .composited ? children : 0),
                "child_windows_failed": JSONValue(snapshot.method == .composited ? 0 : children),
                "floating_windows": JSONValue(together?.floating ?? 0),
                "refusal_hud": hudMessage(services), "refusal_hud_count": JSONValue(services.refusalHUD.shownCount),
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
    @MainActor
    static func captureAsync(_ params: [String: JSONValue], services: AppServices) async -> JSONValue {
        if params["webviews"]?.boolValue == false { return await capture(params, services: services) }
        guard let window = window(params, services: services) else { return .object(["error": .string("no such window")]) }
        let kind = kind(of: window, services: services)
        let path = params["path"]?.stringValue.map { ($0 as NSString).expandingTildeInPath }
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("cmux-window-\(kind)-\(window.windowNumber).png")
        do {
            let webViews = visibleWebViews(in: window)
            // The window server's image first: the window as on screen, WebKit
            // pages, child windows and the app's menus and popovers over it
            // composited together, so glass over the window blurs it. Only
            // without it, AppKit drawing with the live web views hidden, so the
            // page snapshots below fill each rectangle exactly once, and the
            // overlay panels painted on top at the end.
            let together = window.compositedSnapshotWithOverlays()
            let base = try together.map { (image: $0.image, method: WindowSnapshotMethod.composited) }
                ?? (webViews.isEmpty ? appKitBaseImage(for: window) : nativeBaseImage(for: window, hiding: webViews))
            // The overlays cut from the composite now, before the page images' awaits: a popover
            // that opened meanwhile is not in the composite, and its cut would be the window under it.
            let overlays = base.method == .composited
                ? window.overlays(cutFrom: base.image, includeChild: { !WindowOverlayHost.isPageWindow($0) }) : nil
            var layers: [WindowImageLayer] = []
            // The child windows each layer brings, so the result counts only
            // the ones the image includes (none from a missing layer).
            let children = window.visibleChildWindows
            let pageChildren = children.filter(WindowOverlayHost.isPageWindow).count
            var childrenIncluded = base.method == .composited ? children.count : 0
            if base.method == .appkit, let pageWindows = window.childWindowsSnapshot(includeChild: WindowOverlayHost.isPageWindow) {
                layers.append(.window(pageWindows))
                childrenIncluded += pageChildren
            }
            var failed = 0
            for webView in webViews where base.method == .appkit {
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
                    // The page window's holes (find bar, prompt bar, error
                    // page, the whole New Tab page) show the window there, as
                    // on screen.
                    let holes = page.pageWindowHoles.map { page.contentView.convert($0, to: nil) }
                    layers.append(.page(try await page.snapshot(), rect, holes: holes))
                } catch {
                    pagesFailed += 1
                }
            }
            // React pages on the Chromium engine (the agent page, Settings) draw the same way.
            let reactPages = PageRegistry.shownChromiumPages(in: window)
            for (page, rect) in reactPages {
                guard let image = await page.chromiumImage() else { pagesFailed += 1; continue }
                layers.append(.page(image, rect, holes: page.chromiumWindowHoles)) // a chat leaves its pane's tabs uncovered
            }
            var floatingCount = together?.floating ?? 0
            if base.method == .composited {
                // A Chromium page image covered the panels, popovers and menus over its page:
                // their pixels come back from the window server's composite, the page under them.
                if !layers.isEmpty, let overlays {
                    layers.append(.window(overlays))
                }
            } else {
                if let panels = window.childWindowsSnapshot(includeChild: { !WindowOverlayHost.isPageWindow($0) }) {
                    layers.append(.window(panels))
                    childrenIncluded += children.count - pageChildren
                }
                // Menus, and cards or popovers not attached to the window, go on top.
                let floating = window.floatingWindowsSnapshot()
                if let floating { layers.append(.window(floating.image)) }
                floatingCount = floating?.count ?? 0
            }
            let painted = WindowImageLayer.composite(base: base.image, window: window, layers: layers)
            let output = painted ?? base.image
            // AppKit/WebKit capture and compositing stay on the main actor;
            // PNG compression and the file write run off-main.
            try await NSWindow.encodeSnapshotPNG(output, to: URL(fileURLWithPath: path))
            return .object([
                "path": .string(path), "width": JSONValue(output.width), "height": JSONValue(output.height),
                "kind": .string(kind), "window_number": JSONValue(window.windowNumber), "method": .string(base.method.rawValue),
                "webviews": JSONValue(webViews.count), "webviews_composited": JSONValue(webViews.count - failed),
                "webviews_failed": JSONValue(failed), "child_windows": JSONValue(childrenIncluded),
                "child_windows_failed": JSONValue(children.count - childrenIncluded),
                "floating_windows": JSONValue(base.method == .composited || painted != nil ? floatingCount : 0),
                "chromium_pages": JSONValue(pages.count + reactPages.count),
                "chromium_pages_composited": JSONValue(pages.count + reactPages.count - pagesFailed),
                "chromium_pages_failed": JSONValue(pagesFailed),
                "refusal_hud": hudMessage(services), "refusal_hud_count": JSONValue(services.refusalHUD.shownCount),
            ])
        } catch {
            return .object(["error": .string("snapshot failed: \(error.localizedDescription)")])
        }
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// `debug.capture_backdrop` (DEBUG builds): shows `pattern` (`checker`, `stripes`,
    /// `image:/absolute/path`; `none` removes it) just behind the window `window` or `kind` names,
    /// as for a snapshot, so a snapshot of that window composites it behind the window and its
    /// translucency and glass show (``CaptureBackdropPanel``). Returns `pattern`, `window_number`
    /// and `backdrop_number` (null after `none`).
    @MainActor
    static func captureBackdrop(_ params: [String: JSONValue], pattern: CaptureBackdropPattern?, image: Data?,
                                services: AppServices) -> JSONValue {
        let name = params["pattern"]?.stringValue ?? ""
        guard name == "none" || pattern != nil else {
            return .object(["error": .string("pattern must be checker, stripes, image:/absolute/path or none")])
        }
        guard let window = window(params, services: services) else { return .object(["error": .string("no such window")]) }
        var picture: NSImage?
        if case .image(let url) = pattern {
            guard let image, let decoded = NSImage(data: image) else { return .object(["error": .string("no image at \(url.path)")]) }
            picture = decoded
        }
        let backdrop = window.setCaptureBackdrop(pattern, image: picture)
        return .object(["pattern": .string(name), "window_number": JSONValue(window.windowNumber),
                        "backdrop_number": backdrop.map { JSONValue($0.windowNumber) } ?? .null])
    }
    #endif

    /// The refusal HUD's message while it shows, else null.
    static func hudMessage(_ services: AppServices) -> JSONValue {
        services.refusalHUD.message.map(JSONValue.string) ?? .null
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

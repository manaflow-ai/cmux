public import AppKit

/// DevTools of a Chromium tab (Chrome parity): docked below or right of
/// the page inside the pane, resizable, or in its own window. The docked
/// DevTools is a Chromium child window over `devToolsViews.host`, a
/// subview of the tab's content view, so it follows the pane's layout,
/// clipping and moves like the page. DevTools browsers have their own shim
/// client: they never become tabs and never change this tab's URL or title.
extension CEFTab {
    // MARK: Commands

    public func performDevTools(_ command: BrowserDevToolsCommand) {
        guard !isClosed, let browserID, let shim = runtime.shim else { return }
        switch command {
        case .toggle:
            performDevTools(devTools.isOpen ? .close : .show)
        case .show:
            _ = shim.devToolsCommand(browserID, CEFShimLibrary.DevToolsCommand.show, 0, 0)
        case .console:
            _ = shim.devToolsCommand(browserID, CEFShimLibrary.DevToolsCommand.console, 0, 0)
        case .inspectElement:
            _ = shim.devToolsCommand(browserID, CEFShimLibrary.DevToolsCommand.inspect, 0, 0)
        case .close:
            devToolsAfterClose = nil
            _ = shim.devToolsCommand(browserID, CEFShimLibrary.DevToolsCommand.close, 0, 0)
        case .dock(let dock):
            moveDevTools(to: dock)
        }
    }

    public func setDevToolsFocused(_ focused: Bool) {
        guard let browserID, devTools.isOpen else { return }
        runtime.shim?.devToolsSetFocus(browserID, focused ? 1 : 0)
    }

    public func devToolsContains(window: NSWindow) -> Bool {
        guard devTools.isOpen, devTools.dock.isDocked, let host = devToolsViews?.host, let parent = host.window,
              window.parent === parent else { return false }
        let frame = parent.convertToScreen(host.convert(host.bounds, to: nil))
        return frame.contains(NSPoint(x: window.frame.midX, y: window.frame.midY))
    }

    private func moveDevTools(to dock: BrowserDevToolsDock) {
        let wasDocked = devToolsLayout.dock.isDocked
        devToolsLayout.dock = dock
        rememberDevToolsLayout()
        guard devTools.isOpen else {
            devTools.dock = dock
            return
        }
        if wasDocked == dock.isDocked {
            // Bottom <-> right: the same DevTools window, a new frame.
            devTools.dock = dock
            devToolsViews?.divider.needsDisplay = true
            devToolsViews?.divider.window?.invalidateCursorRects(for: devToolsViews!.divider)
            container.layoutContent()
            return
        }
        // A Chromium child window cannot become a top-level window (or the
        // reverse): reopen DevTools in its new place.
        devToolsAfterClose = .show
        if let browserID { _ = runtime.shim?.devToolsCommand(browserID, CEFShimLibrary.DevToolsCommand.close, 0, 0) }
    }

    // MARK: Shim events (CEFRuntime)

    /// Chromium is about to create DevTools for this page (any path:
    /// shortcut, Chrome command, context menu Inspect). Decides its place
    /// now; the shim reads it when this returns.
    func devToolsWillOpen() {
        guard let browserID, let shim = runtime.shim else { return }
        devToolsOpening = true
        if devToolsLayout.dock.isDocked, container.window != nil, runtime.supportsEmbeddedDevTools {
            let views = devToolsViews ?? makeDevToolsViews()
            container.layoutContent()
            let size = views.host.bounds.size
            shim.devToolsSetPlacement(browserID, Unmanaged.passUnretained(views.host).toOpaque(), 0, 0,
                                      Int32(max(size.width, 1)), Int32(max(size.height, 1)))
        } else {
            devToolsOpening = false
            removeDevToolsViews()
            let frame = Self.undockedFrame(near: container.window)
            shim.devToolsSetPlacement(browserID, nil, Int32(frame.minX), Int32(frame.minY),
                                      Int32(frame.width), Int32(frame.height))
        }
    }

    /// Where an undocked DevTools window opens: over the cmux window, inset,
    /// in Chromium's screen coordinates (top-left origin of the primary
    /// screen). Zero (Chromium's default) without a window.
    static func undockedFrame(near window: NSWindow?) -> CGRect {
        guard let window, let primary = NSScreen.screens.first else { return .zero }
        let frame = window.frame.insetBy(dx: 40, dy: 40)
        guard frame.width >= 400, frame.height >= 300 else { return .zero }
        return CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    func devToolsOpened(browser: Int32, docked: Bool) {
        devToolsOpening = false
        devToolsBrowserID = browser
        devTools = BrowserDevToolsState(isOpen: true, dock: docked ? devToolsLayout.dock : .window)
        container.layoutContent()
        devToolsObserver?.browserTab(self, devToolsDidChange: devTools, focused: true)
    }

    func devToolsClosed(browser: Int32) {
        guard devToolsBrowserID == nil || devToolsBrowserID == browser else { return }
        devToolsOpening = false
        devToolsBrowserID = nil
        devTools = BrowserDevToolsState(isOpen: false, dock: devToolsLayout.dock)
        removeDevToolsViews()
        container.layoutContent()
        devToolsObserver?.browserTab(self, devToolsDidChange: devTools, focused: false)
        if let next = devToolsAfterClose {
            devToolsAfterClose = nil
            performDevTools(next)
        }
    }

    // MARK: Layout

    /// Whether the content view reserves room for docked DevTools.
    var reservesDevToolsRoom: Bool {
        devToolsViews != nil && devToolsLayout.dock.isDocked && (devTools.isOpen || devToolsOpening)
    }

    func devToolsFrames(in bounds: CGRect) -> CEFDevToolsLayout.Frames {
        devToolsLayout.frames(in: bounds, devToolsDocked: reservesDevToolsRoom)
    }

    func dragDevToolsDivider(to point: CGPoint) {
        devToolsLayout.dragDivider(to: point, in: container.bounds)
        container.layoutContent()
    }

    func rememberDevToolsLayout() {
        CEFDevToolsLayout.remember(devToolsLayout)
    }

    /// The page's and DevTools' occlusion: the chrome's rects, plus holes
    /// for the divider's grab area so the mouse reaches it over both.
    func applyOcclusion() {
        let frames = devToolsFrames(in: container.bounds)
        if host.visibleTab === self {
            let pageFrame = host.hostView.frame
            var rects = occlusionRects
            if !frames.grab.isEmpty { rects.append(frames.grab) }
            host.hostView.occlusionRects = Self.local(rects, in: pageFrame)
        }
        if let views = devToolsViews {
            views.host.occlusionRects = frames.grab.isEmpty ? [] : Self.local([frames.grab], in: views.host.frame)
        }
    }

    /// `rects` (content view coordinates) in a subview at `frame`.
    private static func local(_ rects: [CGRect], in frame: CGRect) -> [CGRect] {
        rects.compactMap { rect in
            let clipped = rect.intersection(frame)
            guard !clipped.isNull, !clipped.isEmpty else { return nil }
            return clipped.offsetBy(dx: -frame.minX, dy: -frame.minY)
        }
    }

    private func makeDevToolsViews() -> (host: CEFHostView, divider: CEFDevToolsDivider) {
        let host = CEFHostView()
        let divider = CEFDevToolsDivider()
        divider.tab = self
        container.addSubview(host)
        container.addSubview(divider)
        devToolsViews = (host, divider)
        return (host, divider)
    }

    private func removeDevToolsViews() {
        guard let views = devToolsViews else { return }
        devToolsViews = nil
        views.divider.removeFromSuperview()
        views.host.removeFromSuperview()
    }
}

extension CEFTab {
    /// Screen frames of the page area and the docked DevTools area (nil
    /// when not in a window), for `debug.cef`.
    public var devToolsDiagnosticFrames: (page: CGRect, devTools: CGRect?)? {
        guard let window = container.window else { return nil }
        let frames = devToolsFrames(in: container.bounds)
        let screen = { (rect: CGRect) in window.convertToScreen(self.container.convert(rect, to: nil)) }
        return (screen(frames.page), frames.devTools.isEmpty ? nil : screen(frames.devTools))
    }
}

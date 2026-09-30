import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser

/// Makes one window's AppKit first responder, WebKit/CEF page focus,
/// `LayoutModel` focus and the registry context match its `FocusState`
/// (plans/cmux-next/focus.md section 4). Idempotent: every effect compares
/// first. When the target content is not presented yet it does nothing;
/// the pane's `contentPresented` event re-applies. Ghostty surface focus
/// follows the responder (first responder in the key window).
final class FocusEffectApplier: FocusEffectApplying {
    private unowned let controller: WindowController
    /// The CEF page this window gave focus to (blurred when focus leaves).
    private weak var focusedChildWindowPage: AnyObject?
    /// The tab whose docked DevTools this window gave focus to.
    private weak var focusedDevTools: (any BrowserDevToolsHosting)?
    private var observers: [any NSObjectProtocol] = []
    /// The panel bubble over this window that has the keyboard (group editor).
    private weak var overlayPanel: NSWindow?
    private var overlayPanelObserver: (any NSObjectProtocol)?

    init(controller: WindowController) {
        self.controller = controller
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window else { return }
                self?.ownedWindowDidBecomeKey(window)
                self?.childWindowDidBecomeKey(window)
            }
        })
        for (name, active) in [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.controller.focus.send(.appActive(active)) }
            })
        }
        controller.services.observeFocus(of: controller)
    }

    func teardown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        overlayPanelObserver.map(NotificationCenter.default.removeObserver)
        overlayPanelObserver = nil
    }

    /// The content the state describes. While a workspace switch is in
    /// flight the new content reports its topology before the window
    /// installs it; effects then wait for `contentPresented`.
    private var content: WorkspaceContentController? {
        guard let content = controller.content, content.workspace.id == controller.focus.state.topology.workspace else { return nil }
        return content
    }

    func apply(_ effects: [FocusEffect], state: FocusState) {
        for effect in effects {
            switch effect {
            case .select(let pane, let tab):
                if let controller = content?.paneController(key: pane) {
                    controller.applySelection(StripTabID(tab))
                } else {
                    controller.state.selection.select(tab, in: pane)
                }
            case .revealPane(let pane):
                content?.layoutModel.focus(LayoutPaneID(pane), notify: false)
            case .moveResponder(let resolved):
                moveResponder(resolved, state: state)
            case .publishContext(let context):
                publish(context)
            case .browserFocusMode(let tab, let active):
                controller.services.cache.existingBrowser(tab)?.chrome.showsFocusModeIndicator = active
            }
        }
    }

    // MARK: Responder

    private func moveResponder(_ resolved: FocusState.Resolved, state: FocusState) {
        guard let window = controller.window else { return }
        switch resolved {
        case .terminal(let pane, let tab):
            guard case .terminal(let entry)? = presented(pane: pane, tab: tab) else { return }
            blurChildWindowPage()
            let view = entry.session.surfaceView
            if window.firstResponder !== view { window.makeFirstResponder(view) }
        case .browserPage(let pane, let tab):
            guard case .browser(let entry)? = presented(pane: pane, tab: tab) else { return }
            focusPage(entry.tab, in: window)
        case .devTools(let pane, let tab):
            guard case .browser(let entry)? = presented(pane: pane, tab: tab) else { return }
            focusDevTools(of: entry.tab, in: window)
        case .addressBar(let pane, let tab):
            guard case .browser(let entry)? = presented(pane: pane, tab: tab) else { return }
            blurChildWindowPage()
            if !responder(of: window, isInside: entry.chrome.addressBar) { entry.chrome.addressBar.focus() }
        case .findBar(let pane, let tab):
            guard case .browser(let entry)? = presented(pane: pane, tab: tab) else { return }
            blurChildWindowPage()
            if entry.chrome.region(of: window.firstResponder as? NSView ?? window.contentView ?? NSView()) != .findBar {
                entry.chrome.perform(.findInPage)
            }
        case .emptyPane:
            blurChildWindowPage()
            // Nothing to type into: the previous content must not keep keys.
            if let view = window.firstResponder as? NSView, controller.content?.panes.values.contains(where: { view.isDescendant(of: $0.view) }) == true {
                window.makeFirstResponder(nil)
            }
        case .sidebar, .sidebarField, .textField:
            // Reported by AppKit; the responder is already there.
            blurChildWindowPage()
        case .none:
            // Nothing has the keyboard (an empty workspace): no page keeps it
            // (input-spec.md bug B3).
            blurChildWindowPage()
        case .overlay:
            break
        }
    }

    /// The pane's content when it shows `tab` now, else nil (not presented
    /// yet; `contentPresented` re-applies).
    private func presented(pane: String, tab: String) -> TabContent? {
        guard let controller = content?.paneController(key: pane), controller.currentTabKey == tab,
              controller.view.window != nil else { return nil }
        return controller.currentContent
    }

    private func focusPage(_ page: any BrowserTab, in window: NSWindow) {
        // The keyboard moves from the tools back to the page.
        let fromDevTools = focusedDevTools.map { $0 === page } ?? false
        if focusedDevTools != nil { blurDevTools() }
        if fromDevTools { focusedChildWindowPage = nil }
        switch page.presentation {
        case .inView:
            blurChildWindowPage()
            if !responder(of: window, isInside: page.contentView) { setPageFocus(page, true) }
        case .childWindow:
            // Chromium's page is a child window. Its focus is sticky: while
            // this window is key because of a click, the click decides.
            // The page window has the keys: nothing in this window keeps a
            // responder (a field editor or the sidebar would show a caret).
            if window.firstResponder !== window { window.makeFirstResponder(nil) }
            guard focusedChildWindowPage !== page else { return }
            blurChildWindowPage()
            setPageFocus(page, true)
            focusedChildWindowPage = page
        }
    }

    /// The docked DevTools of `page` takes the keyboard (a separate target
    /// inside the pane). No DevTools open: the page keeps it.
    private func focusDevTools(of page: any BrowserTab, in window: NSWindow) {
        guard let devTools = page as? any BrowserDevToolsHosting, devTools.devTools.isOpen else {
            return focusPage(page, in: window)
        }
        if window.firstResponder !== window { window.makeFirstResponder(nil) }
        guard focusedDevTools !== devTools else { return }
        blurDevTools()
        // Not `blurChildWindowPage`: that would make this window key again.
        focusedChildWindowPage = nil
        devTools.setDevToolsFocused(true)
        focusedDevTools = devTools
    }

    private func blurDevTools() {
        guard let devTools = focusedDevTools else { return }
        focusedDevTools = nil
        devTools.setDevToolsFocused(false)
    }

    private func blurChildWindowPage() {
        blurDevTools()
        guard let page = focusedChildWindowPage as? any BrowserTab else { return }
        focusedChildWindowPage = nil
        setPageFocus(page, false)
        if let window = controller.window, let key = NSApp.keyWindow, key.parent === window, !(key is NSPanel) {
            window.makeKey()
        }
    }

    private func setPageFocus(_ page: any BrowserTab, _ focused: Bool) {
        page.setFocused(focused)
        InputJournal.shared.append(window: controller.state.id, .page(tab: page.id.rawValue, focused: focused,
                                                                      engine: page.presentation == .childWindow ? "chromium" : "webkit"))
    }

    private func responder(of window: NSWindow, isInside view: NSView) -> Bool {
        guard let responder = window.firstResponder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: view)
    }

    /// A window this window owns became key (a sheet, a Chromium page
    /// window, the palette, a panel): this window is the active one and
    /// publishes its context, so menus and content shortcuts act where the
    /// keys go (input-spec.md bug B2). A panel bubble other than the palette
    /// (the tab group editor) is an overlay while it has the keys (bug B4).
    private func ownedWindowDidBecomeKey(_ owned: NSWindow) {
        let services = controller.services
        guard owned !== controller.window, services.windows.owner(of: owned) === controller else { return }
        services.windows.didActivate(controller)
        publish(controller.focus.state.context)
        guard owned is NSPanel, owned.sheetParent == nil, !services.palette.owns(owned), overlayPanel == nil else { return }
        overlayPanel = owned
        controller.focus.send(.overlayOpened(.groupEditor))
        overlayPanelObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: owned,
                                                                      queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.overlayPanelDidResignKey() }
        }
    }

    /// The bubble dismisses when it loses the keys.
    private func overlayPanelDidResignKey() {
        overlayPanelObserver.map(NotificationCenter.default.removeObserver)
        overlayPanelObserver = nil
        overlayPanel = nil
        controller.focus.send(.overlayClosed(.groupEditor))
    }

    /// A Chromium page window (a child of this window, not one of our
    /// panels) became key: the user clicked into that page.
    private func childWindowDidBecomeKey(_ child: NSWindow) {
        guard let window = controller.window, child.parent === window, !(child is NSPanel) else { return }
        if let devTools = paneShowingDevTools(window: child) {
            // A click into a docked DevTools: the tools have the keyboard.
            focusedChildWindowPage = nil
            focusedDevTools = devTools.tab
            controller.focus.responderDidChange(.devTools(pane: devTools.key), source: .mouse)
            if window.firstResponder !== window { window.makeFirstResponder(nil) }
            return
        }
        guard let pane = paneShowingChildWindowPage(at: child.frame) else { return }
        focusedDevTools = nil
        focusedChildWindowPage = pane.page
        InputJournal.shared.append(window: controller.state.id, .page(tab: pane.page.id.rawValue, focused: true, engine: "chromium-key"))
        // A click chose the page. Anything else (AppKit restoring key after a
        // panel or sheet) is not a choice: the model re-applies its target,
        // which blurs the page when it is not the target (input-spec.md B7).
        let clicked = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(NSApp.currentEvent?.type)
        controller.focus.responderDidChange(clicked ? .content(pane: pane.key) : .windowOrNone, source: clicked ? .mouse : .programmatic)
        if window.firstResponder !== window { window.makeFirstResponder(nil) }
    }

    private func paneShowingDevTools(window child: NSWindow) -> (key: String, tab: any BrowserDevToolsHosting)? {
        for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
            guard case .browser(let entry)? = pane.currentContent, let devTools = entry.tab as? any BrowserDevToolsHosting,
                  devTools.devToolsContains(window: child) else { continue }
            return (pane.paneKey, devTools)
        }
        return nil
    }

    private func paneShowingChildWindowPage(at frame: NSRect) -> (key: String, page: any BrowserTab)? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
            guard case .browser(let entry)? = pane.currentContent, entry.tab.presentation == .childWindow,
                  let window = pane.view.window else { continue }
            let content = entry.tab.contentView
            let screenFrame = window.convertToScreen(content.convert(content.bounds, to: nil))
            if screenFrame.contains(center) { return (pane.paneKey, entry.tab) }
        }
        return nil
    }

    /// Only the active window publishes into the (app-wide) registry.
    private func publish(_ context: FocusState.Context) {
        let services = controller.services
        guard services.windows.active === controller else { return }
        let registry = services.registry
        var next = registry.context
        next.subtract([.terminalFocused, .browserFocused])
        if context.terminal { next.insert(.terminalFocused) }
        if context.browser { next.insert(.browserFocused) }
        if registry.context != next { registry.context = next }
    }

    // MARK: Diagnostics

    /// The CEF page this window focused, for `debug.focus`.
    var focusedChildWindowPageID: String? { (focusedChildWindowPage as? any BrowserTab)?.id.rawValue }

    /// The tab whose docked DevTools this window focused, for `debug.focus`.
    var focusedDevToolsTabID: String? { (focusedDevTools as? any BrowserTab)?.id.rawValue }
}

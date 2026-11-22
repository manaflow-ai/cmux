import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDesign

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
            MainActor.assumeIsolated { // main-proof: observer on queue: .main
                guard let window else { return }
                self?.ownedWindowDidBecomeKey(window)
                self?.childWindowDidBecomeKey(window)
            }
        })
        for (name, active) in [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { // main-proof: observer on queue: .main
                    self?.controller.focus.send(.appActive(active))
                    if active { self?.reclaimKeyAfterActivation() }
                }
            })
        }
        controller.services.input.observeFocus(of: controller)
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
        // The parked New Tab spare follows the focused pane's size (NewTabSparePool).
        controller.services.newTabSpares.paneLayoutDidChange(in: window)
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
        case .agentPage(let pane, let tab):
            guard case .agent(let view)? = presented(pane: pane, tab: tab) else { return }
            blurChildWindowPage()
            if !responder(of: window, isInside: view) { window.makeFirstResponder(view.webView) }
        case .page(let pane, let tab):
            guard case .page(let view)? = presented(pane: pane, tab: tab) else { return }
            blurChildWindowPage()
            if !responder(of: window, isInside: view) { window.makeFirstResponder(view.focusTarget) }
        case .conversation(let pane, let tab):
            // Home's primary input, its message box (spec/app-screens.md 3).
            blurChildWindowPage()
            guard case .conversation(let view)? = presented(pane: pane, tab: tab) else {
                // No Home view yet: the previous content must not keep keys.
                resignPaneResponder(in: window)
                return
            }
            if !responder(of: window, isInside: view) { window.makeFirstResponder(view.focusTarget) }
        case .emptyPane:
            blurChildWindowPage()
            // Nothing to type into: the previous content must not keep keys.
            resignPaneResponder(in: window)
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

    /// Takes the keyboard from a view inside any pane of this window.
    private func resignPaneResponder(in window: NSWindow) {
        if let view = window.firstResponder as? NSView, controller.content?.panes.values.contains(where: { view.isDescendant(of: $0.view) }) == true {
            window.makeFirstResponder(nil)
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
        if let page = focusedChildWindowPage as? any BrowserTab {
            focusedChildWindowPage = nil
            setPageFocus(page, false)
        }
        reclaimKeyFromPageWindow()
    }

    /// The target is in this window, but one of its Chromium page windows
    /// has the keys (a page Chromium activated without a click, e.g. a new
    /// tab's page window; input-spec.md B11): this window takes them back.
    /// Never activates the app (no key window while it is inactive).
    private func reclaimKeyFromPageWindow() {
        guard let window = controller.window, let key = NSApp.keyWindow, key !== window,
              ChildWindowKeyRule.shouldReclaim(facts(of: key, in: window)) else { return }
        window.makeKey()
    }

    /// AppKit makes the window that was key at deactivation key again while
    /// the app activates; the give-back that ran inside that didBecomeKey
    /// did not hold (nxdog13 desync report 3: `chromium-unchosen-key`, then
    /// W5 200 ms later). Once the app is active, a page window that is not
    /// the target gives the keys back.
    private func reclaimKeyAfterActivation() {
        switch controller.focus.state.resolved {
        case .browserPage, .devTools, .overlay: return
        default: reclaimKeyFromPageWindow()
        }
    }

    /// What the key rule needs to know about `other`, a window that is not
    /// this cmux window.
    private func facts(of other: NSWindow, in window: NSWindow, clicked: Bool = false,
                       overPane: Bool = false, isDevTools: Bool = false) -> ChildWindowKeyRule.Facts {
        let parent: ChildWindowKeyRule.Parent = other.parent === window ? .thisWindow : other.parent == nil ? .none : .other
        return ChildWindowKeyRule.Facts(parent: parent, isPanel: other is NSPanel, isChromiumPage: Self.isChromiumPageWindow(other),
                                        isDevTools: isDevTools, clicked: clicked, overPane: overPane,
                                        thisWindowIsActive: controller.services.windows.active === controller)
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
        // The overlay host panel restores focus itself (`WindowOverlayHost.endModal`).
        guard owned is NSPanel, !(owned is OverlayHostPanel), owned.sheetParent == nil, !services.palette.owns(owned),
              overlayPanel == nil else { return }
        overlayPanel = owned
        controller.focus.send(.overlayOpened(.groupEditor))
        overlayPanelObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: owned,
                                                                      queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.overlayPanelDidResignKey() } // main-proof: observer on queue: .main
        }
    }

    /// The bubble dismisses when it loses the keys.
    private func overlayPanelDidResignKey() {
        overlayPanelObserver.map(NotificationCenter.default.removeObserver)
        overlayPanelObserver = nil
        overlayPanel = nil
        controller.focus.send(.overlayClosed(.groupEditor))
    }

    /// A child window of this window (not one of our panels) became key: a
    /// Chromium page window, its docked DevTools, or a popup over a page.
    /// Only a click into a page is the user's choice.
    private func childWindowDidBecomeKey(_ child: NSWindow) {
        guard let window = controller.window, child !== window else { return }
        let devTools = paneShowingDevTools(window: child)
        let clicked = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(NSApp.currentEvent?.type)
        let pane = paneShowingChildWindowPage(at: child.frame)
        let decision = ChildWindowKeyRule.decide(facts(of: child, in: window, clicked: clicked, overPane: pane != nil,
                                                       isDevTools: devTools != nil))
        switch decision {
        case .ignore:
            return
        case .devTools:
            guard let devTools else { return }
            // A click into a docked DevTools: the tools have the keyboard.
            focusedChildWindowPage = nil
            focusedDevTools = devTools.tab
            controller.focus.responderDidChange(.devTools(pane: devTools.key), source: .mouse)
            if window.firstResponder !== window { window.makeFirstResponder(nil) }
        case .unchosenPage:
            // A page window took the keys without a click: Chromium activated
            // it (a new tab's page, a page script) or AppKit restored key
            // after a panel or sheet. Not a choice: the model re-applies its
            // target, which takes the keys back unless the target is this
            // page (input-spec.md B7, B11, B13). A new page window can also be
            // key before the tracker places it over its pane (pane == nil).
            InputJournal.shared.append(window: controller.state.id, .page(tab: pane?.page.id.rawValue ?? "", focused: false,
                                                                          engine: "chromium-unchosen-key"))
            controller.focus.responderDidChange(.windowOrNone, source: .programmatic)
        case .chosenPage, .reapply:
            guard let pane else { return }
            focusedDevTools = nil
            focusedChildWindowPage = pane.page
            InputJournal.shared.append(window: controller.state.id, .page(tab: pane.page.id.rawValue, focused: true, engine: "chromium-key"))
            // A click chose the page. Another owned window over a pane (an
            // extension popup) keeps the old rule: a key change that is not a
            // click re-applies the model.
            let chosen = decision == .chosenPage
            controller.focus.responderDidChange(chosen ? .content(pane: pane.key) : .windowOrNone, source: chosen ? .mouse : .programmatic)
            if window.firstResponder !== window { window.makeFirstResponder(nil) }
        }
    }

    /// Chromium's page windows (and docked DevTools) are CEF Views windows,
    /// `CefNSWindow`; extension popups and other bubbles are plain
    /// Chromium widget windows.
    private static func isChromiumPageWindow(_ window: NSWindow) -> Bool {
        guard let pageClass = NSClassFromString("CefNSWindow") else { return false }
        return window.isKind(of: pageClass)
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
        if context.agent, case .agentPage(_, let tab) = controller.focus.state.underlying {
            services.agentTabs.setCheckpointFocus(tab)
        } else {
            services.agentTabs.setCheckpointFocus(nil)
        }
        var next = registry.context
        next.subtract(ActionContext.focusBits)
        if context.terminal { next.insert(.terminalFocused) }
        if context.browser { next.insert(.browserFocused) }
        if context.agent { next.insert(.agentPaneFocused) }
        if case .addressBar = controller.focus.state.resolved { next.insert(.omnibarFocused) }
        // The same rule as `KeyRouter.keyContext`: the focused page's id (diff, markdown, code editor).
        switch services.keyRouter.focusedPage(in: controller)?.descriptor.id {
        case KeyRouter.diffPageID?: next.insert(.diffViewerFocused)
        case KeyRouter.markdownPageID?: next.insert(.markdownFocused)
        case KeyRouter.codeEditorPageID?: next.insert(.codeEditorFocused)
        default: break
        }
        if registry.context != next { registry.context = next }
    }

    // MARK: Diagnostics

    /// The CEF page this window focused, for `debug.focus`.
    var focusedChildWindowPageID: String? { (focusedChildWindowPage as? any BrowserTab)?.id.rawValue }

    /// The tab whose docked DevTools this window focused, for `debug.focus`.
    var focusedDevToolsTabID: String? { (focusedDevTools as? any BrowserTab)?.id.rawValue }
}

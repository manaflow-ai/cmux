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
    private var observers: [any NSObjectProtocol] = []

    init(controller: WindowController) {
        self.controller = controller
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { if let window { self?.childWindowDidBecomeKey(window) } }
        })
        for (name, active) in [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.controller.focus.send(.appActive(active)) }
            })
        }
    }

    func teardown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
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
        case .overlay, .none:
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
        switch page.presentation {
        case .inView:
            blurChildWindowPage()
            if !responder(of: window, isInside: page.contentView) { page.setFocused(true) }
        case .childWindow:
            // Chromium's page is a child window. Its focus is sticky: while
            // this window is key because of a click, the click decides.
            // The page window has the keys: nothing in this window keeps a
            // responder (a field editor or the sidebar would show a caret).
            if window.firstResponder !== window { window.makeFirstResponder(nil) }
            guard focusedChildWindowPage !== page else { return }
            blurChildWindowPage()
            page.setFocused(true)
            focusedChildWindowPage = page
        }
    }

    private func blurChildWindowPage() {
        guard let page = focusedChildWindowPage as? any BrowserTab else { return }
        focusedChildWindowPage = nil
        page.setFocused(false)
        if let window = controller.window, let key = NSApp.keyWindow, key.parent === window, !(key is NSPanel) {
            window.makeKey()
        }
    }

    private func responder(of window: NSWindow, isInside view: NSView) -> Bool {
        guard let responder = window.firstResponder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: view)
    }

    /// A Chromium page window (a child of this window, not one of our
    /// panels) became key: the user clicked into that page.
    private func childWindowDidBecomeKey(_ child: NSWindow) {
        guard let window = controller.window, child.parent === window, !(child is NSPanel),
              let pane = paneShowingChildWindowPage(at: child.frame) else { return }
        focusedChildWindowPage = pane.page
        controller.focus.responderDidChange(.content(pane: pane.key), source: .mouse)
        if window.firstResponder !== window { window.makeFirstResponder(nil) }
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
}

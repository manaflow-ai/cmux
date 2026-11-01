import AppKit
import CmuxNextFocusUI
import CmuxNextTerminal

/// Where a creation hold's keys run again (#28436): `AppDelegate` passes `NSApp.sendEvent`, to the key window a person types
/// in; a test, whose window is never key, passes its window. Arguments: the key, the window that held it, the key router.
typealias HeldKeyReplay = @MainActor (NSEvent, NSWindow, KeyRouter) -> Void

/// The App side of the creation holds (`CreationInputCoordinator`, CmuxNextFocusUI): a window's focus and views, its
/// close keys, where held keys run again, and the keys the daemon gave back.
extension KeyRouter: CreationInputHost {
    func creationShell(of window: NSWindow) -> NSWindow? { focus(for: window).0?.window }
    func creationFocus(in window: NSWindow) -> CreationInputFocus {
        let (controller, kind) = focus(for: window)
        guard let controller, let shell = controller.window else { return CreationInputFocus(shell: nil, inContent: false) }
        let state = controller.focus.state
        let expectedTab: String? = if case .tab(let tab)? = state.expectation?.key { tab } else { nil }
        let terminalTab: String? = if case .terminal(_, let tab) = state.resolved { tab } else { nil }
        // The terminal the focus names, when its pane shows it now, and whether its view is the first responder.
        var shown: TerminalEntry?
        if case .terminal(let pane, let tab) = state.resolved, let paneController = controller.content?.paneController(key: pane),
           paneController.currentTabKey == tab, case .terminal(let entry)? = paneController.currentContent { shown = entry }
        let responder = shell.firstResponder as? NSView
        let hasKeyboard = shown.map { entry in responder.map { $0 === entry.session.surfaceView || $0.isDescendant(of: entry.session.view) } ?? false } ?? false
        return CreationInputFocus(shell: shell, inContent: kind == .content, expectedTab: expectedTab,
                                  expectedGeneration: state.expectation?.generation, terminalTab: terminalTab,
                                  takesKeys: Self.responderTakesKeys(controller, window: shell),
                                  terminalHasKeyboard: hasKeyboard, terminalShown: shown != nil)
    }

    func isCloseKey(_ event: NSEvent, in shell: NSWindow) -> Bool {
        guard Self.isChord(event.modifierFlags), let controller = focus(for: shell).0 else { return false }
        let context = keyContext(for: controller.focus.currentState(), facts: facts(in: shell, controller: controller))
        guard let binding = resolve(event, context: context) else { return false }
        return WindowKeyTable.isClose(binding.command)
    }

    func replayHeldKey(_ event: NSEvent, in window: NSWindow) { heldKeyReplay(event, window, self) }
    var lastKeyAction: String? { lastInterception?.action.rawValue }

    /// Keys the daemon gave back from terminal `terminalID`, a creation that did not take them: they
    /// wait for a focused terminal of the window that showed that terminal, never another window's.
    /// Keys from a terminal no window shows any more are dropped (never typed into a guess).
    func giveBack(_ bytes: Data, terminal terminalID: String) {
        GivenBackInput.shared.deliver(adding: bytes, window: window(ofCreatingTerminal: terminalID), to: nil)
        deliverGivenBack()
    }

    /// Hands held give-back keys to the focused terminal (the key window's), when it is in their window.
    func deliverGivenBack() {
        guard let services else { return }
        let focused = services.cache.terminals.values.first { $0.session.model.isFocused && $0.gate == nil }
        let window = focused?.session.view.window.flatMap { services.windows.owner(of: $0)?.state.id }
        GivenBackInput.shared.deliver(window: window, to: focused.map { $0.session.sendBytes })
    }

    /// The cmux window showing the view of terminal `terminalID`, still being created.
    private func window(ofCreatingTerminal terminalID: String) -> String? {
        guard let services,
              let entry = services.cache.terminals.values.first(where: { $0.io.creatingTerminalID == terminalID }),
              let window = entry.session.view.window else { return nil }
        return services.windows.owner(of: window)?.state.id
    }

    /// False while focus names a terminal whose view does not have the keyboard and the window's
    /// first responder is another terminal or the window itself (a remounted view), or names the
    /// pane's selected terminal before its surface is shown: a key now would land in the wrong
    /// terminal or nowhere. Anything else takes the keys.
    static func responderTakesKeys(_ controller: WindowController, window: NSWindow) -> Bool {
        guard case .terminal(let pane, let tab) = controller.focus.state.resolved,
              let paneController = controller.content?.paneController(key: pane) else { return true }
        // Selected, its surface still to come (the pane is empty meanwhile).
        if paneController.currentTabKey != tab { return paneController.stripModel.selectedID?.rawValue != tab }
        guard case .terminal(let entry)? = paneController.currentContent else { return true }
        guard let responder = window.firstResponder as? NSView else { return false }
        if responder === entry.session.surfaceView || responder.isDescendant(of: entry.session.view) { return true }
        return !(responder is TerminalSurfaceView)
    }
}

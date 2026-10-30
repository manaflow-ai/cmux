import CmuxNextTerminal

/// Connects the terminal module's process-wide hooks to the app's services
/// at launch: app-scoped Ghostty actions (`appActionHandler`) and the
/// menu-first rule of a terminal's key equivalents (`menuMayClaim`), and the daemon that
/// sends a TUI its Command chords (`sendToProgram`).
struct TerminalHooks {
    weak var services: AppServices?

    func install() {
        GhosttyRuntime.shared.appActionHandler = { [weak services] in services?.terminalDelegate.performAppAction($0) ?? false }
        TerminalKeyEquivalent.menuMayClaim = { [weak services] in services?.keyRouter.menuMayClaim($0) ?? true }
        // A TUI's Command chord (Cmd-C with nothing selected, Cmd-Z, Cmd-A): the tab's daemon
        // encodes it with the program's keyboard modes. A refused key falls back; one that may have
        // arrived (a timeout) does not, so it never reaches the program twice.
        TerminalKeyEquivalent.sendToProgram = { [weak services] session, chord, fallback in
            guard let services, let key = services.cache.tabKey(for: session),
                  let (tab, pane) = services.locateTabOnAnyMachine(key), tab.kind == .pty else { return false }
            let surface = tab.surface
            services.daemon(for: pane).send("send-key", onFailure: { failure in if !failure.mayHaveApplied { fallback() } }) { try await $0.sendKeys(surface, [chord]) }
            return true
        }
        // A key the dispatcher delivered for the user's own Ghostty keybind.
        TerminalKeyEquivalent.userKeybindOwns = { [weak services] event in
            guard let services, services.keyRouter.decided.contains(event) else { return false }
            return GhosttyKeyBindingLayer.isUsersKeybind(event, layers: services.registry.keyBindingLayers)
        }
    }
}

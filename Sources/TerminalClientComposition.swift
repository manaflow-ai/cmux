/// Process-scoped terminal client dependencies shared by every window,
/// workspace, and Dock in one cmux process.
@MainActor
final class TerminalClientComposition {
    let terminalPanelFactory: any TerminalPanelCreating

    init(terminalPanelFactory: any TerminalPanelCreating) {
        self.terminalPanelFactory = terminalPanelFactory
    }

    static func embedded() -> TerminalClientComposition {
        TerminalClientComposition(
            terminalPanelFactory: EmbeddedTerminalPanelFactory(
                dependencies: GhosttyApp.terminalSurfaceRuntimeDependencies
            )
        )
    }
}

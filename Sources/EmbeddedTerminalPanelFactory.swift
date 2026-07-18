import CmuxTerminal

/// Constructs the existing in-process Ghostty-backed terminal panel.
///
/// A future daemon client can implement `TerminalPanelCreating` without
/// branching inside workspace or Dock state management.
@MainActor
final class EmbeddedTerminalPanelFactory: TerminalPanelCreating {
    private let dependencies: TerminalSurfaceRuntimeDependencies

    init(dependencies: TerminalSurfaceRuntimeDependencies) {
        self.dependencies = dependencies
    }

    func makeTerminalPanel(_ request: TerminalPanelCreationRequest) -> TerminalPanel {
        TerminalPanel(request: request, dependencies: dependencies)
    }
}

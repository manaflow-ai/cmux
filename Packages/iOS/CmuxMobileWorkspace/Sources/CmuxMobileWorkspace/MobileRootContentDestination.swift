/// Root scene branch selected by ``MobileRootAuthGate``.
public enum MobileRootContentDestination: Equatable, Sendable {
    /// Show the terminal layout preview.
    case terminalLayoutPreview
    /// Show the workspace list layout preview.
    case workspaceListLayoutPreview
    /// Show the unauthenticated session-restore state.
    case restoringSession
    /// Show sign-in.
    case signIn
    /// Show the connected workspace shell.
    case workspaceShell
    /// Show stored-Mac reconnect progress.
    case restoringStoredMac
    /// Hold the add-device branch while paired-Mac state is still loading.
    case pairedMacDetermining
    /// Show onboarding.
    case onboarding
    /// Show the disconnected add-device shell for installs with no saved Mac.
    case disconnectedWorkspaceShell
}

import Foundation

/// What the gate asks the App to do.
nonisolated public enum UpdateFlowEffect: Equatable, Sendable {
    /// Install the staged update and relaunch now.
    case install
    /// Download the update that waits for the click.
    case download
    /// Let the quit go on.
    case quit(UpdateQuitAction)
}

/// How a quit treats a staged update.
nonisolated public enum UpdateQuitAction: Equatable, Sendable {
    /// Quit; Sparkle installs a staged update as the app terminates.
    case proceed
    /// `updates.installOnQuit` is off: cancel Sparkle's pending installer
    /// first (the next check offers the update again).
    case cancelPendingInstall
}

/// Inputs of the gate.
nonisolated public enum UpdateFlowEvent: Equatable, Sendable {
    /// Sparkle's flow moved (a scheduled check or the user's).
    case sparkle(UpdateIndicatorPhase)
    /// The user asked to check (palette, menu, CLI).
    case checkRequested
    /// A click on the footer pill, the palette's Install Available Update,
    /// or `cmux update install`.
    case installRequested
    case quitRequested
    /// A note's display time ended.
    case noteExpired
}

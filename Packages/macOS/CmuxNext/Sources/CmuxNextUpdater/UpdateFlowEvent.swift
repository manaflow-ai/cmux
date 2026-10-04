import Foundation

/// What the gate asks the App to do.
nonisolated public enum UpdateFlowEffect: Equatable, Sendable {
    /// Install the staged update and relaunch now.
    case install
    /// Show the CmuxDialog that installs although work runs.
    case confirmInterrupt(UpdateBlockers)
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
    /// A click on the card, or `cmux update install`.
    case installRequested
    /// The waiting card's "Install Now".
    case installNowRequested
    /// The dialog confirmed installing although work runs.
    case interruptConfirmed
    /// The dialog's "Wait".
    case interruptDeclined
    /// "Later" on the waiting card: forget the click, keep the update ready.
    case later
    case blockersChanged(UpdateBlockers)
    case quitRequested
    /// A note's display time ended.
    case noteExpired
}

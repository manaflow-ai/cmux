/// The single close-branch the window's Bonsplit tab-close witness
/// (`splitTabBar(_:shouldCloseTab:inPane:)`) should take for one tab-close
/// request, computed by ``TabCloseDecisionCoordinator`` from already-gathered
/// inputs.
///
/// The witness used to inline a fixed cascade of `if`/`else` branch tests
/// interleaved with the live effects each branch performs. This enum names the
/// seven mutually exclusive branches the cascade selected, in their original
/// precedence order, so the witness asks the coordinator which branch applies
/// and then executes that branch's effects itself. The enum carries no
/// payload: every value the effect needs (the resolved panel id, the remote
/// controller, the localized confirmation strings, the async scheduling) is
/// already held by the witness, which owns all side effects (AppKit alert,
/// `NSSound`, bonsplit mutation, remote-tmux calls, async scheduling,
/// close-history push). Only the branch arbitration moved.
public enum TabCloseDecision: Sendable, Equatable {
    /// The tab mirrors a remote tmux window with a live mirror connection and
    /// is not a programmatic (`forceCloseTabIds`) close: route the close to the
    /// remote (kill-window), running the kill-confirmation flow, and veto the
    /// local close. Highest precedence.
    case routeRemoteTmuxKill

    /// The tab is in `forceCloseTabIds` (a programmatic re-attempt that already
    /// passed confirmation): push close history if eligible, record post-close
    /// state, and allow the close.
    case pushHistoryAndAllow

    /// A close confirmation is already in flight for this window: clear staged
    /// restore/eligibility state and veto, so the in-flight dialog stays the
    /// single arbiter.
    case vetoInFlight

    /// The closing tab's panel is pinned: clear staged state, beep, and veto.
    case beepAndVetoPinned

    /// This is the workspace's last surface under an explicit user close: close
    /// the whole workspace (via the close-button or close-gesture path) and
    /// veto the tab-level close.
    case closeWorkspaceOnLastSurface

    /// The closing tab maps to no panel: stage the closed-browser restore
    /// snapshot if needed, record post-close state, and allow the close.
    case allowImmediate

    /// The panel requires close confirmation: stage state, present the
    /// app-level confirmation, and veto; on confirm, re-attempt the close
    /// through `forceCloseTabIds`.
    case confirmThenForce
}

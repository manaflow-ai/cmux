/// The quit rules (user decision 2026-09-30), free of AppKit and the
/// settings. The App maps `app.quitBehavior` to the remembered choice
/// (`QuitPolicy`) and runs the quit (`QuitCoordinator`).
public struct QuitRules {
    public init() {}

    /// The choice a quit runs with. No quit asks anything (Leo 2026-11-05 on
    /// the "Quit cmux?" alert: "This is, one, unnecessary ... don't show these
    /// kinds of things").
    ///
    /// There is one Quit (CMUX-630, Leo 2026-11-15: "we should just have the
    /// one quit and it's the same quit when i right click the icon in the
    /// dock and it quits while keeping the background services alive. just
    /// less to think about"; "the quit is just the quit of the app, not the
    /// background daemons and whatever"). Cmd-Q, the cmux menu's Quit cmux and
    /// the Dock's Quit are one origin (`interactive`) and always quit only the
    /// app: the daemon, acpmux, the terminal hosts and the agent sessions keep
    /// running whatever `app.quitBehavior` says, so a reopen finds everything
    /// where it was. A person's quit losing nothing, it never asks first (the
    /// "Quit cmux?" question of Lawrence 2026-11-10 guarded a Cmd-Q that could
    /// end the sessions; none can now). Ending the sessions is asked for by
    /// name only: the command palette's Quit and End Sessions, Keep Layout and
    /// Quit and End Everything, or `cmux app quit --end-sessions` /
    /// `--end-everything`. `cmux app quit` with no flag (`scripted`) follows
    /// the remembered choice, where a remembered End Everything ends the
    /// sessions but keeps the workspaces (`unattended`): deleting every
    /// workspace is never one command (2026-10-31: 900 closed by one Cmd-Q).
    public static func decide(_ origin: QuitOrigin, remembered: QuitSessionsChoice?) -> QuitSessionsChoice {
        switch origin {
        // A person's quit quits the app only; power off and SIGTERM never end terminals (the system ends them).
        case .interactive, .powerOff, .signal: .keep
        case .explicit(let choice): choice
        case .scripted: unattended(remembered) ?? .keep
        }
    }

    /// A remembered choice for a quit that runs it unconfirmed: End
    /// Everything ends the sessions but keeps the workspaces.
    public static func unattended(_ remembered: QuitSessionsChoice?) -> QuitSessionsChoice? {
        remembered == .endEverything ? .endKeepLayout : remembered
    }
}

/// The quit rules (user decision 2026-09-30), free of AppKit. The App runs
/// the quit (`QuitCoordinator`).
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
    /// background daemons and whatever"). Cmd-Q, the cmux menu's Quit cmux,
    /// the Dock's Quit and `cmux app quit` with no flag quit only the app: the
    /// daemon, acpmux, the terminal hosts and the agent sessions keep running,
    /// so a reopen finds everything where it was. Nothing remembers another
    /// choice (`app.quitBehavior` and `app.confirmQuit` are retired). Ending
    /// the sessions is asked for by name only: the command palette's Quit and
    /// End Sessions, Keep Layout and Quit and End Everything, or `cmux app quit
    /// --end-sessions` / `--end-everything`.
    public static func decide(_ origin: QuitOrigin) -> QuitSessionsChoice {
        switch origin {
        case .explicit(let choice): choice
        // A person's quit, a script's, power off and SIGTERM never end anything (the system ends what it ends).
        case .interactive, .scripted, .powerOff, .signal: .keep
        }
    }
}

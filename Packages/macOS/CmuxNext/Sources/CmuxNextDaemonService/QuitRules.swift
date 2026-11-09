/// The quit rules (user decision 2026-09-30), free of AppKit and the
/// settings. The App maps `app.quitBehavior` to the remembered choice
/// (`QuitPolicy`) and runs the quit (`QuitCoordinator`).
public struct QuitRules {
    public init() {}

    /// The choice a quit runs with. No quit asks (Leo 2026-11-05 on the
    /// "Quit cmux?" alert: "This is, one, unnecessary ... don't show these
    /// kinds of things"; this takes back QUIT P0's question of 2026-11-01):
    /// a person's Cmd-Q, the menu and the Dock keep the sessions running, or
    /// apply the remembered choice. A remembered End Everything ends the
    /// sessions but keeps the workspaces (`unattended`): deleting every
    /// workspace is never a single keystroke (2026-10-31: 900 closed by one
    /// Cmd-Q). Only "Quit and End Everything" (the cmux menu, the command
    /// palette, `cmux app quit --end-everything`) deletes them.
    public static func decide(_ origin: QuitOrigin, remembered: QuitSessionsChoice?) -> QuitSessionsChoice {
        switch origin {
        // Power off and SIGTERM never end terminals (the system ends them).
        case .powerOff, .signal: .keep
        case .explicit(let choice): choice
        case .interactive, .scripted: unattended(remembered) ?? .keep
        }
    }

    /// A remembered choice for a quit that runs it unconfirmed: End
    /// Everything ends the sessions but keeps the workspaces.
    public static func unattended(_ remembered: QuitSessionsChoice?) -> QuitSessionsChoice? {
        remembered == .endEverything ? .endKeepLayout : remembered
    }
}

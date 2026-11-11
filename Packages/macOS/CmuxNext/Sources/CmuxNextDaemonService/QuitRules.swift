/// The quit rules (user decision 2026-09-30), free of AppKit and the
/// settings. The App maps `app.quitBehavior` to the remembered choice
/// (`QuitPolicy`) and runs the quit (`QuitCoordinator`).
public struct QuitRules {
    public init() {}

    /// The choice a quit runs with. No quit asks how to quit; the App asks
    /// "Quit cmux?" only when a person's quit would end running work
    /// (`QuitConfirmStep`, `app.confirmQuit`, Lawrence 2026-11-10). (Leo 2026-11-05 on the
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

    /// Whether the App asks "Quit cmux?" first (Lawrence 2026-11-10: one
    /// accidental Cmd-Q with End Sessions remembered cut every agent turn and
    /// ended 106 terminals). Only when the answer matters: a person's Cmd-Q,
    /// Quit menu item or Dock Quit whose choice ends the sessions, while an
    /// agent works or a terminal is open, and `app.confirmQuit` (`setting`)
    /// is on. A quit that keeps the sessions loses nothing and never asks;
    /// an explicit quit says what it does (the update relaunch quits as
    /// explicit keep sessions); scripts, signals and power off never wait.
    public static func confirms(_ origin: QuitOrigin, choice: QuitSessionsChoice, setting: Bool, losses: QuitLosses) -> Bool {
        setting && origin == .interactive && choice.ends && !losses.isEmpty
    }

    /// A remembered choice for a quit that runs it unconfirmed: End
    /// Everything ends the sessions but keeps the workspaces.
    public static func unattended(_ remembered: QuitSessionsChoice?) -> QuitSessionsChoice? {
        remembered == .endEverything ? .endKeepLayout : remembered
    }
}

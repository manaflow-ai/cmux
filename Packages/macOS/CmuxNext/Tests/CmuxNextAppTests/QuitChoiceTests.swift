import CmuxNextDaemonService
import Testing

/// One Quit (CMUX-630, Leo 2026-11-15: "we should just have the one quit and it's the same quit when i right click the
/// icon in the dock and it quits while keeping the background services alive. just less to think about"; "the quit is
/// just the quit of the app, not the background daemons and whatever"). Cmd-Q, the Quit cmux menu item, the Dock's Quit
/// and `cmux app quit` with no flag keep every session; nothing remembers another choice. Quit and End Sessions and
/// Quit and End Everything (the command palette, the CLI flags) end them; deleting every workspace is only ever asked
/// for by name (2026-10-31: 900 closed by one Cmd-Q).
struct QuitChoiceTests {
    @Test(arguments: [QuitOrigin.interactive, .scripted, .signal, .powerOff])
    func everyQuitNobodyNamedKeepsTheSessions(origin: QuitOrigin) {
        #expect(QuitRules.decide(origin) == .keep, "\(origin) ended the sessions")
    }

    @Test(arguments: [QuitSessionsChoice.keep, .endKeepLayout, .endEverything])
    func theQuitActionsRunAsAsked(choice: QuitSessionsChoice) {
        #expect(QuitRules.decide(.explicit(choice)) == choice)
    }
}

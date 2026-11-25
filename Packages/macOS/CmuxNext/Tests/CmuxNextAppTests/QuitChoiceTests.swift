@testable import CmuxNextApp
import CmuxNextDaemonService
@testable import CmuxNextSettings
import Testing

/// One Quit (CMUX-630, Leo 2026-11-15: "we should just have the one quit and it's the same quit when i right click the
/// icon in the dock and it quits while keeping the background services alive. just less to think about"; "the quit is
/// just the quit of the app, not the background daemons and whatever"). Cmd-Q, the Quit cmux menu item and the Dock's
/// Quit are one origin and keep every session whatever `app.quitBehavior` says; no quit asks how to quit (Leo
/// 2026-11-05). Quit and End Sessions and Quit and End Everything (the command palette, the CLI flags) end them.
struct QuitChoiceTests {
    @Test(arguments: QuitBehavior.allCases)
    func cmdQMenuAndDockQuitOnlyTheApp(behavior: QuitBehavior) {
        #expect(QuitPolicy.decide(.interactive, behavior: behavior) == .keep, "Cmd-Q with \(behavior) ended the sessions")
    }

    @Test func cmdQKeepsTheSessionsByDefault() {
        #expect(QuitBehaviorSetting.fallback == .keep)
        #expect(QuitPolicy.decide(.interactive, behavior: QuitBehaviorSetting.fallback) == .keep)
    }

    /// `cmux app quit` with no flag still follows the remembered choice.
    @Test(arguments: [(QuitBehavior.keep, QuitSessionsChoice.keep), (.endKeepLayout, .endKeepLayout)])
    func aScriptedQuitAppliesTheRememberedChoice(behavior: QuitBehavior, choice: QuitSessionsChoice) {
        #expect(QuitPolicy.decide(.scripted, behavior: behavior) == choice)
    }

    @Test func signalsAndPowerOffKeepTheSessions() {
        for origin in [QuitOrigin.signal, .powerOff] {
            #expect(QuitPolicy.decide(origin, behavior: .endKeepLayout) == .keep, "\(origin) ended the sessions")
        }
    }

    @Test(arguments: [QuitSessionsChoice.keep, .endKeepLayout, .endEverything])
    func theQuitActionsRunAsAsked(choice: QuitSessionsChoice) {
        #expect(QuitPolicy.decide(.explicit(choice), behavior: .keep) == choice)
    }

    /// "ask" (the removed alert) reads as the default with no diagnostic, so a cmux-next.json that set it keeps working.
    @Test func theOldAskValueReadsAsKeep() {
        let (behavior, diagnostic) = QuitBehaviorSetting.parse(.object(["app": .object(["quitBehavior": .string("ask")])]))
        #expect(behavior == .keep)
        #expect(diagnostic == nil)
    }
}

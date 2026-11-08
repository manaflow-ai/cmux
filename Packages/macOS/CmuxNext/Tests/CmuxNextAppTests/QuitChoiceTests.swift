@testable import CmuxNextApp
import CmuxNextDaemonService
@testable import CmuxNextSettings
import Testing

/// No quit asks how to quit (Leo 2026-11-05 on the "Quit cmux?" alert: "This is, one, unnecessary ... don't show
/// these kinds of things"). A person's Cmd-Q keeps the sessions running, or applies a remembered choice; Quit and End
/// Sessions and Quit and End Everything (the cmux menu, the command palette, the CLI flags) end them.
struct QuitChoiceTests {
    @Test func cmdQKeepsTheSessionsByDefault() {
        #expect(QuitBehaviorSetting.fallback == .keep)
        #expect(QuitPolicy.decide(.interactive, behavior: QuitBehaviorSetting.fallback) == .keep)
    }

    @Test(arguments: [(QuitBehavior.keep, QuitSessionsChoice.keep), (.endKeepLayout, .endKeepLayout)])
    func aRememberedChoiceQuitsWithNoQuestion(behavior: QuitBehavior, choice: QuitSessionsChoice) {
        #expect(QuitPolicy.decide(.interactive, behavior: behavior) == choice)
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

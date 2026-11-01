@testable import CmuxNextApp
import CmuxNextDaemonService
import CmuxNextSettings
import Testing

/// QUIT P0 (Lawrence 2026-11-01: "cmd q needs to prompt for what type of quit"). A person's Cmd-Q with local
/// terminals asks how to quit: Keep Sessions (the default, Return), End Sessions and Keep Layout, End Everything, and
/// Cancel, with "Don't ask again" writing `app.quitBehavior`. A remembered Keep or End Sessions applies with no
/// question (a remembered End Everything asks first: QuitEndEverythingGuardTests), and a script, a signal or power
/// off never asks.
struct QuitChoiceTests {
    private static let twoTerminals = QuitFacts(terminals: 2, programs: [], incognitoPrograms: [], remoteSessions: false)

    @Test func cmdQWithLocalTerminalsAsksWithKeepAsTheDefault() throws {
        let decision = QuitPolicy.decide(.interactive, behavior: .ask, facts: Self.twoTerminals)
        guard case .ask(let prompt) = decision else {
            Issue.record("Cmd-Q with 2 local terminals and app.quitBehavior \"ask\" quit with no question: \(decision)")
            return
        }
        #expect(prompt.offersSessionChoice, "the question did not offer the session choice")
        #expect(prompt.defaultChoice == .keep, "the default (Return) is not Keep Sessions")
        let content = QuitAlertContent.main(prompt)
        #expect(content.buttons.map(\.rawValue) == ["keep", "end-keep-layout", "end-everything", "cancel"],
                "the dialog's buttons, default first")
        #expect(content.showsSuppression, "no \"Don't ask again\" check box")
    }

    @Test(arguments: [(QuitBehavior.keep, QuitSessionsChoice.keep), (.endKeepLayout, .endKeepLayout)])
    func aRememberedChoiceQuitsWithNoQuestion(behavior: QuitBehavior, choice: QuitSessionsChoice) {
        #expect(QuitPolicy.decide(.interactive, behavior: behavior, facts: Self.twoTerminals) == .quit(choice))
    }

    @Test func noLocalTerminalNoQuestion() {
        #expect(QuitPolicy.decide(.interactive, behavior: .ask, facts: .none) == .quit(.keep))
    }

    @Test func scriptsSignalsAndPowerOffNeverAsk() {
        for origin in [QuitOrigin.scripted, .signal, .powerOff] {
            #expect(QuitPolicy.decide(origin, behavior: .ask, facts: Self.twoTerminals) == .quit(.keep), "\(origin) asked")
        }
    }

    @Test func theUnsavedQuestionIsTheQuitsOnlyQuestion() {
        #expect(QuitPolicy.decide(.interactive, behavior: .ask, facts: Self.twoTerminals, alreadyAsked: true) == .quit(.keep))
    }

    @Test func eachButtonAnswersItsChoice() {
        #expect(QuitPolicy.remembered(.keep) == .keep)
        #expect(QuitPolicy.remembered(.endKeepLayout) == .endKeepLayout)
        #expect(QuitPolicy.remembered(.endEverything) == .endEverything)
    }
}

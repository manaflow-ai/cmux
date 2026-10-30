@testable import CmuxNextApp
import CmuxNextDaemonService
import CmuxNextSettings
import Testing

/// `app.confirmQuit` (classic cmux's key) puts "Quit cmux?" back on Cmd-Q,
/// the Quit menu and the Dock: "always" asks every time, "dirty-only" when a
/// program runs or an agent is in a turn, "never" does not ask. Unset, it is
/// "always", as in classic (#25567). A scripted, signal or power-off quit
/// never asks. A stray Cmd-Q quit NIGHTLY with no prompt on 2026-10-19.
struct QuitConfirmPolicyTests {
    private static let idle = QuitFacts(terminals: 2, programs: [], incognitoPrograms: [], remoteSessions: false)
    private static let busy = QuitFacts(terminals: 2, programs: [QuitProgram(name: "vim", cpuNanos: 5)],
                                       incognitoPrograms: [], remoteSessions: false)
    private static let agentWorking = QuitFacts(terminals: 0, programs: [], incognitoPrograms: [], remoteSessions: false,
                                                agents: QuitAgentFacts(live: 1, inTurn: 1, inTurnNames: ["Fix tests"]))

    private func asks(_ decision: QuitDecision) -> QuitPrompt? {
        if case .ask(let prompt) = decision { return prompt }
        return nil
    }

    /// #25567: with no setting, Cmd-Q asks "Quit cmux?" even with nothing running.
    @Test func cmdQAsksByDefault() throws {
        let prompt = try #require(asks(QuitPolicy.decide(.interactive, behavior: .ask, facts: Self.idle)))
        #expect(QuitAlertContent.main(prompt).title == QuitStrings.title)
        #expect(ConfirmQuitMode.fallback == .always)
    }

    @Test func neverQuitsAtOnce() {
        #expect(QuitPolicy.decide(.interactive, behavior: .ask, confirm: .never, facts: Self.busy) == .quit(.keep))
    }

    @Test func alwaysAsksEvenWithNothingRunning() throws {
        let prompt = try #require(asks(QuitPolicy.decide(.interactive, behavior: .ask, confirm: .always, facts: Self.idle)))
        #expect(prompt.offersSessionChoice)
        #expect(prompt.defaultChoice == .keep)
        #expect(QuitAlertContent.main(prompt).title == QuitStrings.title)
    }

    @Test func dirtyOnlyAsksOnlyWhileSomethingRuns() {
        #expect(QuitPolicy.decide(.interactive, behavior: .ask, confirm: .dirtyOnly, facts: Self.idle) == .quit(.keep))
        #expect(asks(QuitPolicy.decide(.interactive, behavior: .ask, confirm: .dirtyOnly, facts: Self.busy)) != nil)
        #expect(asks(QuitPolicy.decide(.interactive, behavior: .ask, confirm: .dirtyOnly, facts: Self.agentWorking)) != nil)
    }

    @Test func onlyAnInteractiveQuitAsks() {
        for origin: QuitOrigin in [.scripted, .signal, .powerOff] {
            #expect(asks(QuitPolicy.decide(origin, behavior: .ask, confirm: .always, facts: Self.busy)) == nil)
        }
    }

    @Test func neverAsksTwice() {
        #expect(QuitPolicy.decide(.interactive, behavior: .ask, confirm: .always, facts: Self.busy, alreadyAsked: true) == .quit(.keep))
    }

    /// "When Quitting" set to End Sessions: the dialog confirms that choice
    /// (Quit, the default button, ends them) instead of offering Keep.
    @Test func aRememberedEndIsWhatQuitDoes() throws {
        let prompt = try #require(asks(QuitPolicy.decide(.interactive, behavior: .endKeepLayout, confirm: .always, facts: Self.idle)))
        #expect(prompt.defaultChoice == .endKeepLayout)
        let content = QuitAlertContent.main(prompt)
        #expect(content.title == QuitStrings.title)
        #expect(content.buttons == [.quit, .cancel])
    }

    /// A held Cmd-Q repeats: a repeat must not answer the dialog it opened.
    @Test func aKeyRepeatDoesNotAnswerTheDialog() {
        #expect(!QuitCoordinator.answersDefault(isKeyRepeat: true))
        #expect(QuitCoordinator.answersDefault(isKeyRepeat: false))
    }

    /// "Don't ask again" in the dialog turns the confirmation off as well as
    /// remembering the choice, so the next Cmd-Q does not ask.
    @MainActor
    @Test func dontAskAgainStopsConfirming() async {
        var remembered: [QuitBehavior] = []
        var stopped = 0
        await QuitCompletion.run(.keep, remember: true, QuitSteps(
            remember: { remembered.append($0) },
            stopConfirming: { stopped += 1 },
            prepareWindows: {},
            endLocalSessions: { _ in [] },
            confirmFailures: { _ in .quitAnyway },
            stopBrowserEngines: {}
        ))
        #expect(remembered == [.keep])
        #expect(stopped == 1)
    }

    @MainActor
    @Test func answeringWithoutTheCheckBoxKeepsConfirming() async {
        var stopped = 0
        await QuitCompletion.run(.keep, remember: false, QuitSteps(
            remember: { _ in },
            stopConfirming: { stopped += 1 },
            prepareWindows: {},
            endLocalSessions: { _ in [] },
            confirmFailures: { _ in .quitAnyway },
            stopBrowserEngines: {}
        ))
        #expect(stopped == 0)
    }
}

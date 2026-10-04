@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextSettings
import Testing

/// Agents outlive the app like terminals (they run in the acpmux daemon),
/// so the quit dialog counts them, and every End choice ends them
/// (plans/cmux-next/quit-persistence.md 4.1, 4.3; R138).
@MainActor
struct QuitAgentsTests {
    static let agentsOnly: QuitFacts = {
        var facts = QuitFacts.none
        facts.agents = QuitAgentFacts(live: 3, inTurn: 2, inTurnNames: ["deploy", "fix-tests"])
        return facts
    }()

    @Test func agentsWithoutTerminalsAsk() {
        guard case .ask(let prompt) = QuitPolicy.decide(.interactive, behavior: .ask, facts: Self.agentsOnly) else {
            Issue.record("expected the dialog"); return
        }
        #expect(prompt.terminals == 0)
        #expect(prompt.agents == 3)
        #expect(prompt.agentsInTurn == 2)
        #expect(prompt.busyAgents == ["deploy", "fix-tests"])
        #expect(prompt.offersSessionChoice)
        #expect(prompt.defaultChoice == .keep)
    }

    @Test func unknownAgentsAsk() {
        var facts = QuitFacts.none
        facts.agents = nil
        guard case .ask(let prompt) = QuitPolicy.decide(.interactive, behavior: .ask, facts: facts) else {
            Issue.record("expected the dialog"); return
        }
        #expect(prompt.agents == nil)
        #expect(prompt.offersSessionChoice)
    }

    @Test func terminalsAndAgentsAreBothCounted() {
        var facts = QuitPolicyTests.idle
        facts.agents = QuitAgentFacts(live: 1, inTurn: 1, inTurnNames: ["a", "b", "c", "d"])
        guard case .ask(let prompt) = QuitPolicy.decide(.interactive, behavior: .ask, facts: facts) else {
            Issue.record("expected the dialog"); return
        }
        #expect(prompt.terminals == 2)
        #expect(prompt.agents == 1 && prompt.agentsInTurn == 1)
        #expect(prompt.busyAgents.count == QuitPolicy.busiestLimit)
    }

    /// The Chief alone never asks; with something else at stake, the dialog
    /// says the Chief keeps running.
    @Test func aChiefTurnIsALineNotACount() {
        var facts = QuitFacts.none
        facts.agents = QuitAgentFacts(live: 0, inTurn: 0, inTurnNames: [], chiefInTurn: true)
        #expect(QuitPolicy.decide(.interactive, behavior: .ask, facts: facts) == .quit(.keep))
        facts.terminals = 1
        guard case .ask(let prompt) = QuitPolicy.decide(.interactive, behavior: .ask, facts: facts) else {
            Issue.record("expected the dialog"); return
        }
        #expect(prompt.agents == 0 && prompt.chiefKeepsRunning)
    }

    @Test func noAgentsAndNoTerminalsQuitWithoutAsking() {
        #expect(QuitPolicy.decide(.interactive, behavior: .ask, facts: .none) == .quit(.keep))
    }

    /// Logout, shutdown, restart, update relaunch (explicit keep), signals
    /// and scripted quits never ask and keep the agents, whatever the setting.
    @Test func nonInteractiveQuitsNeverAskAndKeepAgents() {
        for behavior in QuitBehavior.allCases {
            #expect(QuitPolicy.decide(.powerOff, behavior: behavior, facts: Self.agentsOnly) == .quit(.keep))
            #expect(QuitPolicy.decide(.signal, behavior: behavior, facts: Self.agentsOnly) == .quit(.keep))
            #expect(QuitPolicy.decide(.explicit(.keep), behavior: behavior, facts: Self.agentsOnly) == .quit(.keep))
        }
        #expect(QuitPolicy.decide(.scripted, behavior: .ask, facts: Self.agentsOnly) == .quit(.keep))
    }

    @Test func aRememberedKeepSkipsTheDialogWithAgents() {
        #expect(QuitPolicy.decide(.interactive, behavior: .keep, facts: Self.agentsOnly) == .quit(.keep))
    }

    /// Keep never touches acpmux. Every End choice ends the agents after the
    /// windows save and before the terminals end (the agents' tool shells
    /// must not see their terminals vanish first), and before Chromium stops.
    @Test func endChoicesEndAgentsBeforeTerminalsAndKeepLeavesThem() async {
        let choices: [QuitSessionsChoice] = [.keep, .endKeepLayout, .endEverything]
        for choice in choices {
            let log = AgentStepLog()
            await QuitCompletion.run(choice, remember: false, QuitSteps(
                remember: { _ in log.steps.append("remember") },
                prepareWindows: { log.steps.append("windows") },
                endLocalSessions: { _ in log.steps.append("terminals"); return [] },
                confirmFailures: { _ in log.steps.append("confirm"); return .quitAnyway },
                endLocalAgents: { log.steps.append("agents"); return [] },
                stopBrowserEngines: { log.steps.append("engines") }
            ))
            let expected = choice.ends ? ["windows", "agents", "terminals", "engines"] : ["windows", "engines"]
            #expect(log.steps == expected, "\(choice)")
        }
    }

    /// Agents that do not end are never passed over silently: the failure is
    /// shown with the terminals' failures (Retry, Quit Anyway), and a retry
    /// runs both again.
    @Test func anAgentEndFailureIsShownAndRetried() async {
        let log = AgentStepLog()
        var agentResults = [[EndSessionsFailure(step: .endAgents, message: "acpmux did not exit")], []]
        await QuitCompletion.run(.endKeepLayout, remember: false, QuitSteps(
            remember: { _ in },
            prepareWindows: {},
            endLocalSessions: { _ in log.steps.append("terminals"); return [] },
            confirmFailures: { failures in
                log.steps.append("confirm")
                log.failed.append(contentsOf: failures.map(\.step))
                return .retry
            },
            endLocalAgents: { log.steps.append("agents"); return agentResults.removeFirst() },
            stopBrowserEngines: { log.steps.append("engines") }
        ))
        #expect(log.steps == ["agents", "terminals", "confirm", "agents", "terminals", "engines"])
        #expect(log.failed == [.endAgents])
    }
}

@MainActor
private final class AgentStepLog {
    var steps: [String] = []
    var failed: [EndSessionsFailure.Step] = []
}

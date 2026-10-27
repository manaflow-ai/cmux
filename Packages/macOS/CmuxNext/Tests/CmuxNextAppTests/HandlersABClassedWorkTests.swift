import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// Group 304's handlers (CmuxNextApp/Handlers A* to B*, plans/cmux-next/chrome-parity/p06-scheduler.md recipe R-hop,
/// rule 9): an action's asynchronous rest ends in one main-thread task of its run's class with an owner, never in an
/// unclassed main-actor continuation. `AppActionContext.report` is the shared end of the agent configuration setters
/// and other handlers: a person's run that nobody awaits shows its refusal from a userBlocking task (the rest of
/// their action, rule 2); a CLI run's failure is the answer of its tracked work and shows nothing.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct HandlersABClassedWorkTests {
    private static let cli = ActionRunScope(origin: .cli, allowsViewChange: false)

    /// A main-thread scheduler with no display link: a post runs on the next main run loop pass.
    private static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]), mainWork: MainWorkScheduler.testing(budget: MainFrameBudget()) { _ in nil })
    }

    /// Person: the refusal of work nobody awaits shows once, from a userBlocking task, not from the work's own
    /// continuation.
    @Test func aPersonsUnawaitedFailureIsRefusedFromAUserBlockingTask() async {
        let services = Self.services()
        let seen = HandlersABSeen()
        services.registry.refusalObserver = { reason, _ in
            seen.reasons.append(reason)
            seen.classes.append(services.mainWork.budget.board.running?.workClass)
        }
        AppActionContext(services: services).report { "agentPane.setModel: refused" }
        for _ in 0..<20 where seen.reasons.isEmpty { await drainMainTurns() }
        #expect(seen.reasons == ["agentPane.setModel: refused"], "the person's refusal did not show once")
        #expect(seen.classes == [.userBlocking], "the person's refusal ran outside a userBlocking task: \(seen.classes)")
    }

    /// Automation: a CLI run captures the work and gets its failure as the answer; no notice shows for it.
    @Test func aCLIRunsFailureIsItsAnswerAndShowsNothing() async {
        let services = Self.services()
        let seen = HandlersABSeen()
        services.registry.refusalObserver = { reason, _ in seen.reasons.append(reason) }
        let tasks = services.registry.capturingWork {
            ActionRunScope.$current.withValue(Self.cli) {
                AppActionContext(services: services).report { "agentPane.setMode: refused" }
            }
        }
        #expect(tasks.count == 1, "the capturing caller did not get the work")
        #expect(await tasks.first?.value == "agentPane.setMode: refused")
        await drainMainTurns()
        #expect(seen.reasons.isEmpty, "a CLI run's failure also showed a notice: \(seen.reasons)")
    }

    /// Background: the model catalog is built off main from `_acpmux/models` before one task stores it; the same
    /// rows as before (sorted titles, a short alias per harness, none for an ambiguous short name).
    @Test func theModelCatalogKeepsItsRowsAndAliasesOffMain() {
        let harnesses: [CmuxNextSettings.JSONValue] = [
            ["harness": "local/claude", "models": ["sonnet", ["id": "opus", "name": "Opus"]]],
            ["harness": "peer/codex", "models": ["gpt"]],
            ["harness": "local/codex", "models": ["o3"]],
        ]
        let catalog = AgentConfigurationHandlers.modelCatalog(harnesses)
        #expect(catalog["local/claude"]?.map(\.value) == ["opus", "sonnet"], "rows are not sorted by title")
        #expect(catalog["claude"]?.map(\.value) == ["opus", "sonnet"], "the unique short name lost its alias")
        #expect(catalog["codex"] == nil, "an ambiguous short name got another profile's models")
        #expect(catalog["peer/codex"]?.map(\.value) == ["gpt"])
    }
}

@MainActor
private final class HandlersABSeen {
    var reasons: [String] = []
    var classes: [MainWorkClass?] = []
}

import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// Group 304's handlers (CmuxNextApp/Handlers A* to B*, plans/cmux-next/chrome-parity/p06-scheduler.md recipe R-hop,
/// rule 9): an action's asynchronous rest ends in one main-thread task of its run's class with an owner, never in an
/// unclassed main-actor continuation. `AppActionContext.report` is the shared end of the agent configuration setters
/// and other handlers: a person's run that nobody awaits shows its refusal from a userBlocking task (the rest of
/// their action, rule 2); a CLI run's failure is the answer of its tracked work and shows nothing, and a CLI run
/// nobody awaits shows its refusal from an automation task that yields to the person's key. beside_caller
/// (`AgentBesidePlacement`) waits for the store to list the opened tab on that tab's key and ends at its limit.
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

    /// Automation yields: a CLI run nobody awaits shows its refusal from one automation task, and a person's key that
    /// came first goes first: the refusal waits for that key's frame instead of taking its turn.
    @Test func aCLIRunsUnawaitedRefusalYieldsToThePersonsKey() async {
        _ = NSApplication.shared
        let rig = MainDeadlineRig()
        let services = AppServices(environment: AppEnvironment.current([:]), mainWork: rig.work)
        let seen = HandlersABSeen()
        services.registry.refusalObserver = { reason, _ in
            seen.reasons.append(reason)
            seen.classes.append(rig.work.budget.board.running?.workClass)
        }
        ActionRunScope.$current.withValue(Self.cli) {
            AppActionContext(services: services).report {
                seen.worked = true
                return "agentPane.setMode: refused"
            }
        }
        // The person presses a key that changes what shows, before the run's refusal reaches main.
        rig.work.noteDiscreteDispatch(began: true)
        rig.work.noteDiscreteInput(expectsFrame: true)
        rig.work.noteDiscreteDispatch(began: false)
        let end = Date(timeIntervalSinceNow: 5)
        while seen.reasons.isEmpty, !(seen.worked && rig.work.postedCount(.automation) > 0), Date() < end {
            runMainLoopPass(for: 0.01)
            await Task.yield()
        }
        #expect(seen.worked, "the run's work never ran")
        #expect(seen.reasons.isEmpty, "the CLI run's refusal ran before the frame of the person's key")
        #expect(rig.work.postedCount(.automation) > 0, "the CLI run's refusal is not a queued automation task")
        var frames = 0
        while seen.reasons.isEmpty, frames < 60 {
            frames += 1
            rig.frame()
        }
        #expect(seen.reasons == ["agentPane.setMode: refused"], "the CLI run's refusal never showed")
        #expect(seen.classes == [.automation], "the CLI run's refusal ran outside an automation task: \(seen.classes)")
        #expect(frames >= 1, "the CLI run's refusal ran before any frame after the person's key")
        withExtendedLifetime(services) {}
    }

    /// The model catalog the setters build from `_acpmux/models` keeps the same rows as before (sorted titles, a
    /// short alias per harness, none for an ambiguous short name).
    @Test func theModelCatalogKeepsItsRowsAndAliases() {
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

    // MARK: beside_caller (AgentBesidePlacement)

    /// An agent's tab opened beside its chat: the move waits for the store to list the opened surface (a keyed store
    /// wait, not a poll), then ends done in one automation task (the CLI's run) with no failure.
    @Test func besideCallerEndsDoneOnceTheStoreListsTheOpenedTab() async throws {
        let services = Self.services()
        let store = services.daemon.store
        store.apply(snapshot: Self.besideTree())
        let anchor = try #require(store.workspaces.first?.screens.first?.panes.first, "the fixture has no chat pane")
        let (task, place) = try Self.placeBeside(anchor, services: services, limit: .seconds(10))
        place(Self.opened)
        // The surface came; the store has not listed its tab yet.
        await store.waiters.untilPending(1)
        #expect(Self.classes(of: "AgentBesidePlacement.reveal", on: services).isEmpty, "the move ended before the store listed the tab")
        // The daemon lists the opened tab in the column right of the chat.
        _ = store.apply(.tabAdded(TabDelta(workspace: Self.workspace, screen: Self.screen, pane: Self.besidePane, surface: Self.opened,
                                           index: nil, entity: TabSnapshot(surface: Self.opened))))
        let failure = await Self.value(of: task)
        #expect(failure == nil, "the move did not end done: \(failure?.message ?? "")")
        #expect(Self.classes(of: "AgentBesidePlacement.reveal", on: services) == [.automation],
                "the CLI's move did not end in one automation task")
        #expect(store.waiters.pendingCount == 0, "the move left its store wait filed")
    }

    /// A tab the store never lists ends the move at its limit, in one automation task, and the run answers why.
    @Test func besideCallerEndsAtItsLimitWhenTheStoreNeverListsTheTab() async throws {
        let services = Self.services()
        let store = services.daemon.store
        store.apply(snapshot: Self.besideTree())
        let anchor = try #require(store.workspaces.first?.screens.first?.panes.first, "the fixture has no chat pane")
        let limit: Duration = .milliseconds(80)
        let (task, place) = try Self.placeBeside(anchor, services: services, limit: limit)
        let start = ContinuousClock.now
        place(Self.opened)
        let failure = await Self.value(of: task)
        let waited = ContinuousClock.now - start
        #expect(failure?.message == "beside-caller: the new tab did not open")
        #expect(waited >= limit, "the move ended \(waited) in, before its \(limit) limit")
        #expect(Self.classes(of: "AgentBesidePlacement.notOpened", on: services) == [.automation],
                "the CLI's move did not end at its limit in one automation task")
        #expect(store.waiters.pendingCount == 0, "the limit left the store wait filed")
    }

    // MARK: Helpers

    private static let workspace: WorkspaceHandle = 1
    private static let screen: ScreenID = 100
    private static let chatPane: PaneID = 10
    private static let besidePane: PaneID = 20
    /// The surface of the tab the agent opens.
    private static let opened: SurfaceID = 304

    /// Workspace 1: the chat's pane 10 (tab 1) and pane 20 right of it (tab 2).
    private static func besideTree() -> DaemonTree {
        let panes = [PaneSnapshot(id: chatPane, tabs: [TabSnapshot(surface: 1)]), PaneSnapshot(id: besidePane, tabs: [TabSnapshot(surface: 2)])]
        let layout = LayoutNode.split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(chatPane), b: .leaf(besidePane))
        let screens = [ScreenSnapshot(id: screen, layout: layout, panes: panes)]
        return DaemonTree(workspaceRevision: 1, workspaces: [WorkspaceSnapshot(id: workspace, key: nil, name: "w1", screens: screens)])
    }

    /// A CLI run's beside_caller open from `anchor`, a pane no window shows: its tracked move, and the `then` the
    /// open calls with the new tab's surface.
    private static func placeBeside(_ anchor: PaneModel, services: AppServices, limit: Duration) throws
        -> (ActionWork, @MainActor (SurfaceID) -> Void) {
        var invocation = ActionInvocation(origin: .cli)
        invocation.besideCaller = true
        invocation.newColumnBeside = true
        var placed: (@MainActor (SurfaceID) -> Void)?
        let tasks = services.registry.capturingWork {
            ActionRunScope.$current.withValue(Self.cli) {
                placed = AgentBesidePlacement.placed(invocation, pane: anchor, controller: nil, services: services, limit: limit, then: nil)
            }
        }
        let task = try #require(tasks.first, "the beside move reported no work to the capturing run")
        return (task, try #require(placed, "the beside move returned no open callback"))
    }

    /// `work`'s answer, with the main run loop running while it is awaited: its main-thread steps are tasks posted to
    /// the run loop, and its limits are run loop timers.
    private static func value(of work: ActionWork) async -> ActionWorkFailure? {
        let answer = HandlersABAnswer()
        // task-owner: the test's one read of the work's answer
        let reader = Task {
            answer.failure = await work.value
            answer.done = true
        }
        let end = Date(timeIntervalSinceNow: 5)
        while !answer.done, Date() < end {
            runMainLoopPass(for: 0.01)
            await Task.yield()
        }
        await reader.value
        return answer.failure
    }

    /// The classes `owner`'s tasks ran in, from the scheduler's owner ledger.
    private static func classes(of owner: String, on services: AppServices) -> [MainWorkClass] {
        services.mainWork.budget.board.ownerSnapshot().owners.filter { $0.owner == owner }.map(\.workClass)
    }
}

@MainActor
private final class HandlersABSeen {
    var reasons: [String] = []
    var classes: [MainWorkClass?] = []
    var worked = false
}

@MainActor
private final class HandlersABAnswer {
    var failure: ActionWorkFailure?
    var done = false
}

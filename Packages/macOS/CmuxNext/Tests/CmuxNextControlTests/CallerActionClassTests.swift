import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// What a caller's run with no target does is decided per action, for every action of the catalog
/// (`ControlRouter.callerClass(of:)`): it opens beside an agent, runs on the caller's own place, must have its
/// object named (it closes or destroys it), acts on the person's front window (an agent cannot run it unnamed),
/// or is not affected by a caller. Reviews of 4b4017014c8 and 79f350e1deb: `cmux cloud archive-session` with no
/// `--session` archived the agent's own session; a destructive browser action reached the nearest browser, the
/// person's; `cmux workspace close-all` closed the workspaces of the window the person had in front.
///
/// These run each action of the app's REAL catalog through `action.run` as an agent with no target. A new action
/// has no reviewed class (CallerActionClassReview) and fails the first test whatever its name, until someone decides.
@MainActor @Suite(.timeLimit(.minutes(5))) struct CallerActionClassTests {
    /// The arguments of closing actions that say how, not what: the object still comes from a target.
    static let qualifierArguments: Set<String> = [
        "browser.download.cancel.download", "browser.extension.remove.extension", "browser.pageInfo.deleteSiteData.domain",
        "cloudFileRemove.path", "cloudPortClose.port", "cloudPreviewRevoke.linkId", "cloudPreviewRevoke.port",
        "palette.cloud.deleteSnapshot.snapshot", "space.delete.moveTo",
    ]

    /// The agent's workspace (CallerOwnPlacementTests: an agent's terminal with a browser on its right, in a
    /// workspace no window shows; the person's focus is in another workspace) with the app's real catalog, every
    /// context fact on so that no action is refused for a missing focus.
    static func snapshot() -> ControlSnapshot {
        var snapshot = CallerOwnPlacementTests.snapshot(right: [CallerOwnPlacementTests.pane("pane-web", [CallerOwnPlacementTests.browser("tab-web")])])
        let real = RegistryControlBridge.catalog(from: ActionRegistry.standard())
        snapshot.catalog = ControlCatalog(actions: real.actions, contextMask: .max, aliases: real.aliases, targetKinds: real.targetKinds,
                                          debugActionsAvailable: true)
        return snapshot
    }

    /// Whether `target` names something of the agent's own workspace in `snapshot`.
    static func isInAgentWorkspace(_ target: ControlTargetRef?, _ snapshot: ControlSnapshot) -> Bool {
        guard let target, let workspace = snapshot.topology.workspaces.first(where: { $0.id == "ws-agent" }) else { return false }
        return target.id == workspace.id || workspace.screens.contains { $0.id == target.id }
            || workspace.panes.contains { $0.id == target.id || $0.tabs.contains { $0.id == target.id } }
    }

    @Test func everyActionOfTheRealCatalogHasAReviewedClass() {
        let actions = Self.snapshot().catalog.actions
        #expect(actions.count > 1_000, "the real catalog: \(actions.count) actions")
        var undecided: [String] = []
        var counts: [CallerActionClass: Int] = [:]
        for action in actions {
            let derived = ControlRouter.callerClass(of: action)
            counts[derived, default: 0] += 1
            // A catalog field or a hand list of the router decides these three; a review decides the default two.
            let reviewed: Bool = switch derived {
            case .opensBeside, .closing, .windowClosing: true
            case .ownPlace: CallerActionClassReview.ownPlace.contains(action.id)
            case .unaffected: CallerActionClassReview.unaffected.contains(action.id)
            }
            if !reviewed { undecided.append("\(action.id) (\(derived.rawValue) by default, targets \(action.targets))") }
        }
        #expect(undecided.isEmpty, """
            \(undecided.count) action(s) with no reviewed class. Decide each: does an agent's run of it with no target close, \
            end or destroy something (ControlRouter.closingActions, .windowClosingActions), open a tab beside the agent \
            (.besideCallerActions), or neither (CallerActionClassReview, in the list of its default class)? \(undecided)
            """)
        for each in CallerActionClass.allCases { #expect(counts[each, default: 0] > 0, "no action is \(each.rawValue)") }
        // The hand lists name real actions only (a renamed action is not silently unguarded), and each id has one decision.
        let ids = Set(actions.map(\.id))
        let byHand = ControlRouter.closingActions.union(ControlRouter.windowClosingActions).union(ControlRouter.besideCallerActions)
        #expect(byHand.subtracting(ids).isEmpty, "\(byHand.subtracting(ids).sorted())")
        #expect(byHand.isDisjoint(with: CallerActionClassReview.ownPlace.union(CallerActionClassReview.unaffected)))
        #expect(CallerActionClassReview.ownPlace.isDisjoint(with: CallerActionClassReview.unaffected))
        #expect(ControlRouter.closingActions.isDisjoint(with: ControlRouter.windowClosingActions))
    }

    /// Each class does what it says: an agent's run of every action, with its caller and no target.
    @Test func anAgentsTargetlessRunOfEveryActionFollowsItsClass() async throws {
        let executor = RecordingExecutor()
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: .loadTolerant)
        let snapshot = Self.snapshot()
        router.snapshots.publish { $0 = snapshot }
        var ran: [CallerActionClass: Int] = [:]
        for action in snapshot.catalog.actions where action.disabledFeature == nil {
            let before = executor.requests.withLock { $0.count }
            // `interactive`: a missing required argument is asked for later, so the run reaches its placement.
            let result = await router.handle(ControlRequest(id: "1", method: "action.run", params: [
                "action": .string(action.id), "interactive": true, "wait": false, "caller": CallerOwnPlacementTests.agent,
            ]))
            let request = executor.requests.withLock { $0.count > before ? $0.last : nil }
            let derived = ControlRouter.callerClass(of: action)
            if request != nil { ran[derived, default: 0] += 1 }
            switch derived {
            case .closing, .windowClosing:
                #expect(request == nil, "\(action.id) ran for an agent that named nothing")
                let refusal = ControlRouter.objectArguments(of: action).isEmpty && action.targets.isEmpty ? "person_required" : "target_required"
                #expect(result.failure?.code == refusal, "\(action.id) \(action.targets): \(String(describing: result))")
                #expect(result.failure?.message.contains("tab-agent") != true, "\(action.id) offers the agent its own tab")
            case .opensBeside, .ownPlace:
                // Wherever it ran, it ran in the agent's own workspace (its own place, or the browser nearest it).
                if let request { #expect(Self.isInAgentWorkspace(request.target, snapshot), "\(action.id): \(String(describing: request.target))") }
            case .unaffected:
                if let request { #expect(request.target == nil, "\(action.id) was aimed at \(String(describing: request.target))") }
            }
        }
        // The loop exercised the classes that run, not only their refusals.
        #expect(ran[.ownPlace, default: 0] > 100, "\(ran)")
        #expect(ran[.unaffected, default: 0] > 100, "\(ran)")
        #expect(ran[.opensBeside, default: 0] > 3, "\(ran)")
    }

    /// A closing action whose object is named by its own argument is not refused, and is not aimed at the
    /// caller's own tab or workspace; and every other text or number argument of a closing action is a
    /// reviewed qualifier, so a new naming argument cannot go unnoticed.
    @Test func aClosingRunThatNamesItsObjectByArgumentIsNotRefused() async throws {
        let executor = RecordingExecutor()
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: .loadTolerant)
        let snapshot = Self.snapshot()
        router.snapshots.publish { $0 = snapshot }
        var undecided: [String] = []
        var named = 0
        for action in snapshot.catalog.actions {
            let derived = ControlRouter.callerClass(of: action)
            guard derived == .closing || derived == .windowClosing else { continue }
            let objects = ControlRouter.objectArguments(of: action)
            for argument in action.arguments where argument.kind != .bool && argument.kind != .enumeration && !objects.contains(argument.name) {
                if !Self.qualifierArguments.contains(action.id + "." + argument.name) { undecided.append(action.id + "." + argument.name) }
            }
            for name in objects {
                guard let argument = action.arguments.first(where: { $0.name == name }) else { continue }
                // A window of the topology for a target argument; any text for the others.
                let value: JSONValue = argument.kind == .target ? .string((argument.targetKind ?? "window") + ":win-1") : "named-by-argument"
                let before = executor.requests.withLock { $0.count }
                let result = await router.handle(ControlRequest(id: "1", method: "action.run", params: [
                    "action": .string(action.id), "interactive": true, "wait": false, "args": .object([name: value]),
                    "caller": CallerOwnPlacementTests.agent,
                ]))
                #expect(!["target_required", "person_required"].contains(result.failure?.code ?? ""), "\(action.id) --\(name): \(String(describing: result))")
                if let request = executor.requests.withLock({ $0.count > before ? $0.last : nil }) {
                    #expect(request.target == nil, "\(action.id) --\(name) was also aimed at \(String(describing: request.target))")
                }
                named += 1
            }
        }
        #expect(undecided.isEmpty, """
            arguments of closing actions with no decision: does each name the object the action closes (ControlRouter \
            .objectArgumentExceptions, when the schema does not show it) or only qualify it (qualifierArguments)? \(undecided)
            """)
        #expect(named >= 4, "the session, bookmark, window and browser-profile arguments: \(named)")
    }

    /// A person's shell is not an agent: its close with no target closes its own tab, as it asked, and its
    /// Close All Workspaces acts on the front window as before.
    @Test func aPersonsShellIsNotRefused() async throws {
        let executor = RecordingExecutor()
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: .loadTolerant)
        var plain = CallerOwnPlacementTests.snapshot(own: CallerOwnPlacementTests.terminal("tab-agent", "term-agent", agent: nil))
        plain.catalog = Self.snapshot().catalog
        router.snapshots.publish { $0 = plain }
        _ = try await router.handle(ControlRequest(id: "1", method: "action.run", params: [
            "action": "closeTab", "wait": false, "caller": CallerOwnPlacementTests.agent,
        ])).get()
        #expect(executor.last?.target == ControlTargetRef(kind: "tab", id: "tab-agent"))
        _ = try await router.handle(ControlRequest(id: "2", method: "action.run", params: [
            "action": "workspace.closeAll", "wait": false, "args": ["confirm": true], "caller": CallerOwnPlacementTests.agent,
        ])).get()
        #expect(executor.last?.actionID == "workspace.closeAll")
        #expect(executor.last?.target == nil)
    }
}

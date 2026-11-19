import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// What a caller's run with no target does is decided per action, for every action of the catalog
/// (`ControlRouter.callerClass(of:)`): it opens beside an agent, runs on the caller's own place, must have its
/// object named (it closes or destroys it), acts on the person's front window, Space or bookmark (an agent
/// cannot run it unnamed), or is not affected by a caller. Reviews of 4b4017014c8, 79f350e1deb and 4fb5810d35c:
/// `cmux cloud archive-session` with no `--session`, or with an empty one, archived the agent's own session; a
/// destructive browser action reached the nearest browser, the person's; `cmux workspace close-all` closed the
/// workspaces of the window the person had in front; an agent's Ungroup or Move Group to New Window took the
/// group of the tab the person had focused; Minimize and Stop Chief acted on the person's front window.
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
            case .opensBeside, .closing, .personsFront: true
            case .ownPlace: CallerActionClassReview.ownPlace.contains(action.id)
            case .unaffected: CallerActionClassReview.unaffected.contains(action.id)
            }
            if !reviewed { undecided.append("\(action.id) (\(derived.rawValue) by default, targets \(action.targets))") }
        }
        #expect(undecided.isEmpty, """
            \(undecided.count) action(s) with no reviewed class. Decide each: does an agent's run of it with no target close, \
            end or destroy something (ControlRouter.closingActions, .windowClosingActions), change the person's front \
            window or its Chief (.frontWindowActions), open a tab beside the agent (.besideCallerActions), or none of \
            these (CallerActionClassReview, in the list of its default class)? Read its handler: does it take the \
            focused tab, pane, workspace or the front window when the run has no target? \(undecided)
            """)
        for each in CallerActionClass.allCases { #expect(counts[each, default: 0] > 0, "no action is \(each.rawValue)") }
        // The hand lists name real actions only (a renamed action is not silently unguarded), and each id has one decision.
        let ids = Set(actions.map(\.id))
        let byHand = ControlRouter.closingActions.union(ControlRouter.windowClosingActions).union(ControlRouter.besideCallerActions)
            .union(ControlRouter.profileBrowserActions).union(ControlRouter.frontWindowActions)
        let named = byHand.union(ControlRouter.ownPlaceByHand.keys).union(ControlRouter.frontReadingActions)
        #expect(named.subtracting(ids).isEmpty, "\(named.subtracting(ids).sorted())")
        #expect(ControlRouter.windowClosingActions.isDisjoint(with: ControlRouter.frontWindowActions))
        // The actions of the two reviews of 4fb5810d35c are where their handlers put them.
        let classes = Dictionary(actions.map { ($0.id, ControlRouter.callerClass(of: $0)) }, uniquingKeysWith: { first, _ in first })
        for id in ["tabGroup.ungroup", "tabGroup.moveToNewWindow", "tabGroup.moveToNewWorkspace", "tabGroup.moveToWorkspace", "tabGroup.moveToNewSplit",
                   "tabGroup.newTab", "screenGroup.rename", "workspaceGroup.rename", "toggleUnread", "screenGroup.reopenSaved"] {
            #expect(classes[id] == .ownPlace, "\(id): \(String(describing: classes[id]))")
        }
        for id in ["minimizeWindow", "zoomWindow", "home.stopChief", "home.stopAllAgents", "toggleFullScreen", "window.toggleDock", "space.rename",
                   "space.next", "space.previous", "bookmark.open", "workspace.closeAll"] {
            #expect(classes[id] == .personsFront, "\(id): \(String(describing: classes[id]))")
        }
        #expect(classes["window.screenshot"] == .unaffected)
        // A history entry's page opens beside the caller, as its browser does (review of 369c9dd76d1).
        #expect(classes["history.open"] == .opensBeside)
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
            case .closing, .personsFront:
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
            guard derived == .closing || derived == .personsFront else { continue }
            let objects = ControlRouter.objectArguments(of: action)
            // The qualifier review is of what closes: an action on the person's front object that closes nothing has
            // arguments (a name, a color) that say what to do, and it is refused unnamed whatever they hold.
            let closes = derived == .closing || ControlRouter.windowClosingActions.contains(action.id)
            for argument in action.arguments where closes && argument.kind != .bool && argument.kind != .enumeration && !objects.contains(argument.name) {
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
                // An empty or blank value names nothing: the run is refused as one with no argument is (review of
                // 4fb5810d35c: `cloud archive-session --session ""` archived the agent's own session).
                for blank in argument.kind == .target ? [] : ["", "  "] {
                    let ran = executor.requests.withLock { $0.count }
                    let refused = await router.handle(ControlRequest(id: "1", method: "action.run", params: [
                        "action": .string(action.id), "interactive": true, "wait": false, "args": .object([name: .string(blank)]),
                        "caller": CallerOwnPlacementTests.agent,
                    ]))
                    #expect(executor.requests.withLock { $0.count } == ran, "\(action.id) --\(name) '\(blank)' ran for an agent that named nothing")
                    #expect(refused.failure?.code == "target_required", "\(action.id) --\(name) '\(blank)': \(String(describing: refused))")
                }
            }
        }
        #expect(undecided.isEmpty, """
            arguments of closing actions with no decision: does each name the object the action closes (ControlRouter \
            .objectArgumentExceptions, when the schema does not show it) or only qualify it (qualifierArguments)? \(undecided)
            """)
        #expect(named >= 4, "the session, bookmark, window and browser-profile arguments: \(named)")
    }

    /// An action on a group runs on the group of the agent's own tab, screen or workspace, never on the group of
    /// what the person has focused; an action on the person's front window or its Chief is refused for an agent,
    /// runs for a Chief turn (Stop Chief from its own turn stops its own Chief), and runs for an agent that names
    /// the window.
    @Test func aGroupActionRunsOnTheCallersOwnAndAFrontWindowActionNeedsItsWindow() async throws {
        let executor = RecordingExecutor()
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: .loadTolerant)
        router.snapshots.publish { $0 = Self.snapshot() }
        func run(_ action: String, caller: JSONValue = CallerOwnPlacementTests.agent, target: String? = nil) async -> (ControlActionRequest?, ControlError?) {
            let before = executor.requests.withLock { $0.count }
            var params: [String: JSONValue] = ["action": .string(action), "interactive": true, "wait": false, "caller": caller]
            if let target { params["target"] = .string(target) }
            let result = await router.handle(ControlRequest(id: "1", method: "action.run", params: params))
            return (executor.requests.withLock { $0.count > before ? $0.last : nil }, result.failure)
        }
        for action in ["tabGroup.ungroup", "tabGroup.moveToNewWindow", "tabGroup.moveToNewWorkspace", "tabGroup.moveToWorkspace", "tabGroup.moveToNewSplit"] {
            let (request, failure) = await run(action)
            #expect(request?.target == ControlTargetRef(kind: "tab", id: "tab-agent"), "\(action): \(String(describing: request?.target)) \(String(describing: failure))")
        }
        #expect(await run("screenGroup.rename").0?.target == ControlTargetRef(kind: "screen", id: "screen-agent"))
        #expect(await run("workspaceGroup.rename").0?.target == ControlTargetRef(kind: "workspace", id: "ws-agent"))

        for action in ["minimizeWindow", "zoomWindow", "space.next", "space.previous", "home.stopChief", "home.stopAllAgents", "toggleFullScreen"] {
            let (request, failure) = await run(action)
            #expect(request == nil, "\(action) ran on the person's front window for an agent")
            #expect(failure?.code == "person_required", "\(action): \(String(describing: failure))")
            let (chief, refused) = await run(action, caller: ["home_chat": true])
            #expect(chief != nil && chief?.target == nil, "a Chief turn's \(action): \(String(describing: refused))")
        }
        let (unnamed, refusal) = await run("window.toggleDock")
        #expect(unnamed == nil)
        #expect(refusal?.code == "target_required", "\(String(describing: refusal))")
        #expect(refusal?.message.contains("window:<id>") == true, "\(String(describing: refusal?.message))")
        #expect(await run("window.toggleDock", target: "window:win-1").0?.target == ControlTargetRef(kind: "window", id: "win-1"))
        // Reopen Saved Screen Group and a history entry run in the agent's own workspace, never the focused one.
        #expect(await run("screenGroup.reopenSaved").0?.target == ControlTargetRef(kind: "pane", id: "pane-agent"))
        let history = await run("history.open").0
        #expect(Self.isInAgentWorkspace(history?.target, Self.snapshot()), "\(String(describing: history?.target))")
        #expect(history?.besideCaller == true)
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

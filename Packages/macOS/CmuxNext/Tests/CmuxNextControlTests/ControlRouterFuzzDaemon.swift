import CmuxFuzzSupport
import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation

/// A window, workspace, screen, pane, tab or terminal of the fake daemon's topology, live or closed.
struct RouterFuzzObject: Sendable, Hashable {
    var kind: String
    var id: String
}

/// The daemon behind ControlRouterFuzzTests (p10-stability-177): the router's executor and the
/// topology it publishes. Every `action.run` the router lets through lands here, on the main actor,
/// as it lands in `RegistryControlBridge`; the daemon answers with an outcome drawn from its own
/// seeded generator, starts work tasks that succeed, fail, return a value or stall until the next
/// step, and applies the action's effect (a workspace or tab created, the target closed or focused)
/// to the topology it publishes. Ids are never reused, so an id it closed names nothing again.
///
/// It also audits what reached it: an action the catalog does not list, an argument outside its
/// schema, or a target the router resolved although the daemon had closed it before the step began.
/// Chrome's MojoLPM fuzzers check the same kind of contract at the browser side of an IPC interface
/// (mojo/public/tools/fuzzers/mojolpm.h): the receiver must never see a message validation refuses.
@MainActor
final class RouterFuzzDaemon: ControlActionExecutor {
    /// Kinds the router resolves against the topology (PublicIDTargetResolver), normalized.
    static let resolvedKinds: Set<String> = ["window", "workspace", "screen", "pane", "tab", "surface", "terminal"]
    static let windowID = "win-00000"
    /// Past this many tabs the daemon applies no more creates, so a sequence stays small.
    static let tabLimit = 256

    private(set) var topology = ControlTopology()
    /// What reached the daemon that the router should have refused.
    private(set) var violations: [String] = []
    /// Actions the daemon ran or refused.
    private(set) var calls = 0
    /// Every id the daemon closed, in order.
    private(set) var closed: [RouterFuzzObject] = []
    /// Set by the test before each command: its deadline is the control-plane one, so a stalled
    /// work task ends with the request's timeout, not a minute later.
    var mayStall = false

    private var rng: FuzzRNG
    /// False: every action runs with no work and no effect (the deterministic tests).
    private let scripted: Bool
    private let actions: [String: ControlActionInfo]
    private var snapshots: ControlSnapshotStore?
    private var counter = 0
    private var closedIDs: Set<String> = []
    private var closedBeforeStep: Set<String> = []
    private var resolvesTargets = true
    private var stalls: [AsyncStream<Void>.Continuation] = []

    init(catalog: ControlCatalog, seed: UInt64, scripted: Bool = true) {
        rng = FuzzRNG(seed: seed)
        self.scripted = scripted
        actions = Dictionary(catalog.actions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        topology.isLoaded = true
        topology.daemonState = "connected"
        topology.workspaces = [makeWorkspace()]
    }

    /// Publishes the topology to `store` (the router's), now and after every change.
    func attach(_ store: ControlSnapshotStore) {
        snapshots = store
        publish()
    }

    /// Every object the topology lists now.
    var live: [RouterFuzzObject] {
        topology.windows.map { RouterFuzzObject(kind: "window", id: $0.id) } + topology.workspaces.flatMap { Self.objects(in: $0) }
    }

    var sequence: UInt64 { topology.daemonSequence }

    // MARK: - Steps

    /// Called before each command: releases the work that stalled in the last one (its reply
    /// arrives late) and notes what is closed by now.
    func beginStep() {
        releaseStalls()
        closedBeforeStep = closedIDs
        resolvesTargets = topology.isLoaded
    }

    func releaseStalls() {
        for stall in stalls { stall.finish() }
        stalls.removeAll()
    }

    /// The daemon's event sequence for `after: "sync"`; refused while it is disconnected.
    func syncSequence() throws(ControlError) -> UInt64 {
        guard topology.daemonState == "connected" else {
            throw ControlError(code: "unavailable", message: "the fuzz daemon is disconnected")
        }
        return topology.daemonSequence
    }

    // MARK: - ControlActionExecutor

    func performAction(_ request: ControlActionRequest) -> ControlActionOutcome {
        performActionTracked(request).outcome
    }

    func performActionTracked(_ request: ControlActionRequest) -> ControlActionRun {
        calls += 1
        audit(request)
        guard scripted else { return ControlActionRun(outcome: .ran) }
        if let target = request.target, isResolved(target), !isLive(target.id) {
            return ControlActionRun(outcome: .notFound("the fuzz daemon has no \(target.kind) \(target.id)"))
        }
        let outcome = drawOutcome()
        let created = outcome == .ran ? applyEffect(of: request) : nil
        return ControlActionRun(outcome: outcome, work: drawWork(), results: drawResults(created: created))
    }

    // MARK: - Topology changes (also the daemon's own events between commands)

    @discardableResult
    func createWorkspace() -> String? {
        guard topology.tabCount < Self.tabLimit else { return nil }
        let workspace = makeWorkspace()
        topology.workspaces.append(workspace)
        publish()
        return workspace.id
    }

    /// Adds a tab to pane `paneID` (any pane when nil); nil when there is no such pane.
    @discardableResult
    func createTab(in paneID: String?) -> String? {
        guard topology.tabCount < Self.tabLimit else { return nil }
        for w in topology.workspaces.indices {
            for s in topology.workspaces[w].screens.indices {
                for p in topology.workspaces[w].screens[s].panes.indices where paneID == nil || topology.workspaces[w].screens[s].panes[p].id == paneID {
                    let tab = makeTab()
                    topology.workspaces[w].screens[s].panes[p].tabs.append(tab)
                    publish()
                    return tab.id
                }
            }
        }
        return nil
    }

    /// Closes the workspace, screen, pane or tab `id` and what it holds; a pane, screen or
    /// workspace left empty closes with it.
    func close(_ id: String) {
        var gone: [RouterFuzzObject] = []
        topology.workspaces = topology.workspaces.compactMap { workspace -> ControlWorkspaceInfo? in
            guard workspace.id != id else {
                gone += Self.objects(in: workspace)
                return nil
            }
            var workspace = workspace
            workspace.screens = workspace.screens.compactMap { screen -> ControlScreenInfo? in
                guard screen.id != id else {
                    gone += Self.objects(in: screen)
                    return nil
                }
                var screen = screen
                screen.panes = screen.panes.compactMap { pane -> ControlPaneInfo? in
                    guard pane.id != id else {
                        gone += Self.objects(in: pane)
                        return nil
                    }
                    var pane = pane
                    gone += pane.tabs.filter { $0.id == id }.flatMap { Self.objects(in: $0) }
                    pane.tabs.removeAll { $0.id == id }
                    guard !pane.tabs.isEmpty else {
                        gone.append(RouterFuzzObject(kind: "pane", id: pane.id))
                        return nil
                    }
                    if !pane.tabs.contains(where: { $0.id == pane.selectedTabID }) { pane.selectedTabID = pane.tabs.first?.id }
                    return pane
                }
                guard !screen.panes.isEmpty else {
                    gone.append(RouterFuzzObject(kind: "screen", id: screen.id))
                    return nil
                }
                return screen
            }
            guard !workspace.screens.isEmpty else {
                gone.append(RouterFuzzObject(kind: "workspace", id: workspace.id))
                return nil
            }
            return workspace
        }
        guard !gone.isEmpty else { return }
        closed += gone
        closedIDs.formUnion(gone.map(\.id))
        publish()
    }

    /// The daemon connection drops: the mirror stays (`unloaded` false) or is gone.
    func disconnect(unloaded: Bool) {
        topology.daemonState = "disconnected"
        topology.isLoaded = !unloaded
        publish()
    }

    func reconnect() {
        topology.daemonState = "connected"
        topology.isLoaded = true
        publish()
    }

    /// A daemon event that changes nothing the topology shows.
    func bumpSequence() {
        publish()
    }

    // MARK: - Private

    private func audit(_ request: ControlActionRequest) {
        guard let action = actions[request.actionID] else {
            violations.append("\(request.actionID) is not a registered action")
            return
        }
        var refs = request.target.map { [$0] } ?? []
        for (name, value) in request.arguments {
            guard let argument = action.arguments.first(where: { $0.name == name }) else {
                violations.append("\(action.id) got argument \(name), which its schema does not have")
                continue
            }
            switch (argument.kind, value) {
            case (.string, .string), (.bool, .bool):
                break
            case (.int, .int(let number)):
                if let range = argument.range, !range.contains(number) {
                    violations.append("\(action.id) argument \(name) is \(number), outside \(range)")
                }
            case (.enumeration, .string(let choice)):
                if !argument.choices.contains(where: { $0.value == choice }) {
                    violations.append("\(action.id) argument \(name) is \(choice.debugDescription), not one of its choices")
                }
            case (.target, .target(let ref)):
                refs.append(ref)
            default:
                violations.append("\(action.id) argument \(name) is \(value), not of kind \(argument.kind.rawValue)")
            }
        }
        guard resolvesTargets else { return }
        for ref in refs where isResolved(ref) && closedBeforeStep.contains(ref.id) {
            violations.append("\(action.id) got target \(ref), which the daemon closed before the step")
        }
    }

    private func isResolved(_ ref: ControlTargetRef) -> Bool {
        Self.resolvedKinds.contains(ControlRouter.normalizedKind(ref.kind))
    }

    private func isLive(_ id: String) -> Bool {
        live.contains { $0.id == id }
    }

    private func drawOutcome() -> ControlActionOutcome {
        switch rng.below(32) {
        case 0: .refused("the fuzz daemon refuses")
        case 1: .notFound("the fuzz daemon lost it")
        case 2: .unavailable
        case 3: .disabled
        case 4: .notBound
        case 5: .confirmationRequired
        case 6: .featureDisabled("fuzz.feature")
        case 7: .unknownAction
        default: .ran
        }
    }

    /// The action's effect on the topology; returns the id it created, if any.
    private func applyEffect(of request: ControlActionRequest) -> String? {
        let target = request.target.map(\.id)
        switch rng.below(8) {
        case 0:
            return createWorkspace()
        case 1:
            let pane = request.target.flatMap { target -> String? in target.kind == "pane" ? target.id : topology.tab(id: target.id)?.pane.id }
            return createTab(in: pane)
        case 2:
            if let target { close(target) }
            return nil
        case 3:
            if let target { focus(target) }
            return nil
        default:
            return nil
        }
    }

    private func drawWork() -> [ActionWork] {
        switch rng.below(12) {
        case 0:
            let failure = ActionWorkFailure("the fuzz daemon failed", mayHaveApplied: rng.bool(), terminalMayAppear: rng.oneIn(4))
            return [ActionWork { () -> ActionWorkFailure? in failure }]
        case 1:
            let failure = ActionWorkFailure(code: "fuzz.unavailable", reason: "the fuzz daemon has no such thing")
            return [ActionWork { () -> ActionWorkFailure? in failure }]
        case 2:
            guard mayStall, rng.oneIn(4) else { return [] }
            // The reply comes late: the work ends when the next step begins (or the sequence ends).
            let (late, reply) = AsyncStream<Void>.makeStream()
            stalls.append(reply)
            return [ActionWork { () -> ActionWorkFailure? in
                for await _ in late {}
                return nil
            }]
        case 3, 4, 5:
            return (0...rng.below(3)).map { _ in ActionWork { () -> ActionWorkFailure? in nil } }
        default:
            return []
        }
    }

    private func drawResults(created: String?) -> [ActionResultWork] {
        switch rng.below(8) {
        case 0:
            var fields: [String: ActionResultValue] = ["count": .int(rng.int(in: -3...3)), "nested": .object(["list": .array([.null, .bool(true), .double(0.5)])])]
            if let created { fields["id"] = .string(created) }
            let value = fields
            return [ActionResultWork { () -> Result<[String: ActionResultValue], ActionWorkFailure> in .success(value) }]
        case 1:
            return [ActionResultWork { () -> Result<[String: ActionResultValue], ActionWorkFailure> in .failure("the fuzz daemon has no value") }]
        default:
            return []
        }
    }

    private func focus(_ id: String) {
        if let found = topology.tab(id: id) {
            topology.focus = ControlFocus(windowID: Self.windowID, workspaceID: found.workspace.id, paneID: found.pane.id, tabID: found.tab.id)
        } else if let found = topology.pane(id: id) {
            topology.focus = ControlFocus(windowID: Self.windowID, workspaceID: found.workspace.id, paneID: found.pane.id, tabID: found.pane.selectedTabID)
        } else if let workspace = topology.workspace(id: id) {
            let pane = workspace.panes.first
            topology.focus = ControlFocus(windowID: Self.windowID, workspaceID: workspace.id, paneID: pane?.id, tabID: pane?.selectedTabID)
        } else {
            return
        }
        publish()
    }

    /// Moves focus off closed objects, lists the workspaces in the one window, bumps the
    /// sequence and publishes.
    private func publish() {
        let focused = topology.focus.tabID.flatMap { topology.tab(id: $0) }
        if focused == nil {
            let workspace = topology.workspaces.first
            let pane = workspace?.panes.first
            topology.focus = ControlFocus(windowID: Self.windowID, workspaceID: workspace?.id, paneID: pane?.id, tabID: pane?.selectedTabID)
        }
        topology.windows = [ControlWindowInfo(id: Self.windowID, workspaceID: topology.focus.workspaceID, workspaceIDs: topology.workspaces.map(\.id),
                                              isKey: true, isVisible: true, focusedPaneID: topology.focus.paneID)]
        topology.daemonSequence &+= 1
        let published = topology
        snapshots?.publish(rebuilt: true) { $0.topology = published }
    }

    /// A fixed-width id, so a closed id is never a prefix of a live one (the resolver takes unique prefixes).
    private func nextID(_ prefix: String) -> String {
        counter += 1
        let digits = String(counter)
        return prefix + "-" + String(repeating: "0", count: max(0, 5 - digits.count)) + digits
    }

    private func makeTab() -> ControlTabInfo {
        let id = nextID("tab")
        return ControlTabInfo(id: id, surface: "s" + id, kind: rng.oneIn(3) ? "browser" : "terminal", title: "fuzz",
                              terminalID: "term" + id.dropFirst(3), columns: 80, rows: 24, cwd: "/tmp")
    }

    private func makeWorkspace() -> ControlWorkspaceInfo {
        let tab = makeTab()
        let pane = ControlPaneInfo(id: nextID("pane"), handle: String(counter), selectedTabID: tab.id, tabs: [tab])
        let screen = ControlScreenInfo(id: nextID("screen"), handle: String(counter), panes: [pane])
        let id = nextID("ws")
        return ControlWorkspaceInfo(id: id, handle: String(counter), name: "Fuzz " + id, screens: [screen])
    }

    private static func objects(in workspace: ControlWorkspaceInfo) -> [RouterFuzzObject] {
        [RouterFuzzObject(kind: "workspace", id: workspace.id)] + workspace.screens.flatMap { objects(in: $0) }
    }

    private static func objects(in screen: ControlScreenInfo) -> [RouterFuzzObject] {
        [RouterFuzzObject(kind: "screen", id: screen.id)] + screen.panes.flatMap { objects(in: $0) }
    }

    private static func objects(in pane: ControlPaneInfo) -> [RouterFuzzObject] {
        [RouterFuzzObject(kind: "pane", id: pane.id)] + pane.tabs.flatMap { objects(in: $0) }
    }

    private static func objects(in tab: ControlTabInfo) -> [RouterFuzzObject] {
        [RouterFuzzObject(kind: "tab", id: tab.id)] + (tab.terminalID.map { [RouterFuzzObject(kind: "terminal", id: $0)] } ?? [])
    }
}

/// `settings.*` storage in memory: the router's file actor without a file.
actor RouterFuzzSettings: ControlSettingsStore {
    private var root: JSONValue = ["appearance": ["density": "compact"]]

    nonisolated var fileLocation: String { "/nonexistent/cmux-router-fuzz/cmux.json" }

    func value(at path: [String]) -> JSONValue? { root.value(at: path) }

    func set(_ value: JSONValue, at path: [String]) { root = Self.setting(value, at: path[...], in: root) }

    func remove(_ path: [String]) { root = Self.setting(nil, at: path[...], in: root) }

    private static func setting(_ value: JSONValue?, at path: ArraySlice<String>, in node: JSONValue) -> JSONValue {
        guard let key = path.first else { return value ?? .null }
        var members = node.objectValue ?? [:]
        members[key] = path.count == 1 ? value : .some(setting(value, at: path.dropFirst(), in: members[key] ?? .object([:])))
        return .object(members)
    }
}

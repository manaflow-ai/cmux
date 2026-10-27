import AppKit
import CmuxNextBridge
import CmuxNextBridgeUI
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// The shared matrix's sidebar-order cases (Tests/Matrix/cases.json,
/// cx-rq6i5) on the app's own placement: sidebar order is the home
/// session's personal order, which the app computes and the daemon only
/// stores, so the core runner cannot check it. Each case seeds three
/// workspaces in personal order (and, for a create, the new one somewhere
/// the case does not expect it), then places the moving workspace as the
/// app does: a create as `WindowManager.applyPendingPlacements` does once
/// the daemon lists it (slot → position → `SidebarBridge.place`), Move to
/// Bottom through `WorkspaceVerbHandlers.place`. It checks both what the
/// sidebar shows at once (the optimistic edit) and the personal order the
/// app's plan writes, applied as the daemon applies `set-personal-workspace`
/// (remove, insert at min(index, count)). No daemon, no window, no clock.
/// The slot table mirrors the handler bindings; the HID and CLI runners
/// cover the bindings themselves. Move Up/Down writes the daemon only and
/// is left to the HID runner. Every failure starts with "MATRIX <case id>:".
@MainActor @Suite(.serialized)
struct ModelMatrixPersonalOrderTests {
    /// The slot each covered action resolves to, given its target (WorkspaceVerbHandlers).
    static let slots: [String: (String) -> WorkspaceSlot] = [
        "workspace.newAbove": { .above($0) },
        "workspace.newBelow": { .below($0) },
        "workspace.newAtTop": { _ in .top(anchor: nil) },
        "workspace.newAtBottom": { _ in .bottom(anchor: nil) },
        "workspace.moveToBottom": { .bottom(anchor: $0) },
    ]
    static let creates: Set<String> = ["workspace.newAbove", "workspace.newBelow", "workspace.newAtTop", "workspace.newAtBottom"]
    /// `$w1`...`$w3` are the seeded workspaces, `$new` the created one.
    static let keys = ["$w1": "k1", "$w2": "k2", "$w3": "k3", "$new": "k4"]
    static let seeded = ["k1", "k2", "k3"]

    static func cases() throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Matrix/cases.json")
        let file = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try #require(file["cases"] as? [[String: Any]]).filter { item in
            let action = (item["action"] as? [String: Any])?["id"] as? String ?? ""
            return slots[action] != nil && item["state"] as? String == "ws3"
        }
    }

    /// The sidebar of one window listing `rowed` in that personal order, on a
    /// home session with or without `personal-mixed-order-v1`.
    static func sidebar(_ rowed: [String], mixedOrder: Bool) throws -> (AppServices, SidebarBridge) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let capabilities = mixedOrder ? #","capabilities":["personal-mixed-order-v1"]"# : ""
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1""# + capabilities + "}"
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        var tree = DaemonTree(registryID: "s-local", workspaces: rowed.sorted().enumerated().map { index, key in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key)
        })
        tree.personal = PersonalState(workspaces: rowed.enumerated().map { index, key in
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: key), index: index)
        })
        store.apply(snapshot: tree)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"matrix","workspace_key":"matrix-home"}"#.utf8))
        let state = WindowState(record: record)
        services.windows.registry.provisional[state.id] = rowed
        let bridge = SidebarBridge(services: services, state: state)
        bridge.resync()
        return (services, bridge)
    }

    static func order(_ bridge: SidebarBridge) -> [String] {
        bridge.model.selectableWorkspaces.map(\.id.rawValue)
    }

    /// `order` after the plan's steps, as the daemon applies each one.
    static func applying(_ plan: PersonalSidebarPlanner.DropPlan, to order: [String]) -> [String] {
        var order = order
        for step in plan.steps {
            let key = step.workspace.key.rawValue
            order.removeAll { $0 == key }
            order.insert(key, at: min(step.index, order.count))
        }
        return order
    }

    /// Runs one case; returns its failures.
    static func run(_ item: [String: Any], mixedOrder: Bool) throws -> [String] {
        let id = item["id"] as? String ?? "?"
        let action = item["action"] as? [String: Any] ?? [:]
        let actionID = action["id"] as? String ?? ""
        guard let target = keys[action["target"] as? String ?? ""], let slot = slots[actionID]?(target) else {
            return ["MATRIX \(id): no target or slot"]
        }
        let expects = (item["expect"] as? [[String: Any]] ?? []).filter { $0["code"] as? String == "order-is" && $0["of"] as? String == "workspaces" }
        guard let expect = expects.first, expects.count == 1 else { return ["MATRIX \(id): needs one workspace order-is"] }
        let wanted = (expect["ids"] as? [String] ?? []).map { keys[$0] ?? $0 }
        let isCreate = creates.contains(actionID)
        let moving = isCreate ? "k4" : target
        // A create starts the new workspace at the first slot the case does not expect, so no case passes unmoved.
        let starts = isCreate ? (0...seeded.count).map { var rows = seeded; rows.insert("k4", at: $0); return rows } : [seeded]
        guard let rowed = starts.first(where: { $0 != wanted }) else { return ["MATRIX \(id): every start is the expected order"] }
        let (services, bridge) = try sidebar(rowed, mixedOrder: mixedOrder)
        guard order(bridge) == rowed else { return ["MATRIX \(id): seeded \(order(bridge)), expected \(rowed)"] }
        let machine = try #require(services.machines.daemon(forWorkspace: moving)?.machineID)
        let section = CmuxNextSidebar.SectionID.machine(CmuxNextSidebar.MachineID(machine))
        let sections = SidebarRowSection.withoutPlaceholders(bridge.model.sections)
        guard let position = slot.position(moving: [moving], section: section, in: sections) else {
            return ["MATRIX \(id): the slot names no position"]
        }
        guard let plan = PersonalSidebarPlanner(machines: services.machines).dropPlan([SidebarWorkspaceID(moving)], at: position, in: sections) else {
            return ["MATRIX \(id): no personal plan"]
        }
        var failures: [String] = []
        let written = applying(plan, to: rowed)
        if written != wanted { failures.append("MATRIX \(id): personal order \(written), expected \(wanted)") }
        if isCreate {
            bridge.place([SidebarWorkspaceID(moving)], at: position, in: sections)
        } else {
            let workspace = try #require(services.machines.local.store.workspaces.first { $0.id == moving })
            if !WorkspaceVerbHandlers.place(workspace, slot, in: bridge, services: services) {
                return failures + ["MATRIX \(id): the sidebar does not list \(moving)"]
            }
        }
        if order(bridge) != wanted { failures.append("MATRIX \(id): sidebar order \(order(bridge)), expected \(wanted)") }
        return failures
    }

    @Test(arguments: [false, true])
    func everySidebarOrderCaseHoldsOnThePlacement(mixedOrder: Bool) throws {
        let cases = try Self.cases()
        #expect(cases.count >= 13, "MATRIX: only \(cases.count) sidebar-order cases found")
        var failures: [String] = []
        for item in cases { failures += try Self.run(item, mixedOrder: mixedOrder) }
        #expect(failures.isEmpty, "\(failures.count) sidebar-order failures (mixed order \(mixedOrder)):\n\(failures.joined(separator: "\n"))")
    }
}

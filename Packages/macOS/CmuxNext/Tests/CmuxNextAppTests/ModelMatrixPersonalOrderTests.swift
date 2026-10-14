import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// The shared matrix's sidebar-order cases (Tests/Matrix/cases.json,
/// cx-rq6i5) on the app's own placement: sidebar order is the home
/// session's personal order, which the app computes and the daemon only
/// stores, so the core runner cannot check it. Each case seeds three
/// workspaces in personal order (and, for a create, the new one as its
/// daemon lists it), runs the slot its action resolves to through
/// `WorkspaceVerbHandlers.place`, the step every positioned create and
/// Move to Bottom ends in, and reads the sidebar's order at once (the
/// optimistic edit; no daemon, no window, no clock). Move Up/Down writes
/// the daemon only and is left to the HID runner. Every failure starts
/// with "MATRIX <case id>:".
@MainActor @Suite(.serialized)
struct ModelMatrixPersonalOrderTests {
    /// The slot each covered action resolves to, given its target.
    static let slots: [String: (String) -> WorkspaceSlot] = [
        "workspace.newAbove": { .above($0) },
        "workspace.newBelow": { .below($0) },
        "workspace.newAtTop": { _ in .top(anchor: nil) },
        "workspace.newAtBottom": { _ in .bottom(anchor: nil) },
        "workspace.moveToBottom": { .bottom(anchor: $0) },
    ]
    static let creates: Set<String> = ["workspace.newAbove", "workspace.newBelow", "workspace.newAtTop", "workspace.newAtBottom"]

    static func cases() throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Matrix/cases.json")
        let file = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try #require(file["cases"] as? [[String: Any]]).filter { item in
            let action = (item["action"] as? [String: Any])?["id"] as? String ?? ""
            return slots[action] != nil && item["state"] as? String == "ws3"
        }
    }

    /// `$w1`...`$w3` are the seeded workspaces, `$new` the created one.
    static let keys = ["$w1": "k1", "$w2": "k2", "$w3": "k3", "$new": "k4"]

    /// The sidebar after seeding `keys` (in personal order `rowed`) on a
    /// home session with or without `personal-mixed-order-v1`.
    static func sidebar(listing keys: [String], rowed: [String], mixedOrder: Bool) throws -> (AppServices, SidebarBridge) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let capabilities = mixedOrder ? #","capabilities":["personal-mixed-order-v1"]"# : ""
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1""# + capabilities + "}"
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        var tree = DaemonTree(registryID: "s-local", workspaces: keys.enumerated().map { index, key in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key)
        })
        tree.personal = PersonalState(workspaces: rowed.enumerated().map { index, key in
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: key), index: index)
        })
        store.apply(snapshot: tree)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"matrix","workspace_key":"matrix-home"}"#.utf8))
        let state = WindowState(record: record)
        services.windows.registry.provisional[state.id] = keys
        let bridge = SidebarBridge(services: services, state: state)
        bridge.resync()
        return (services, bridge)
    }

    static func order(_ bridge: SidebarBridge) -> [String] {
        bridge.model.allWorkspaces.map(\.id.rawValue)
    }

    @Test(arguments: [false, true])
    func everySidebarOrderCaseHoldsOnThePlacement(mixedOrder: Bool) throws {
        let cases = try Self.cases()
        #expect(cases.count >= 13, "MATRIX: only \(cases.count) sidebar-order cases found")
        var failures: [String] = []
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let action = try #require(item["action"] as? [String: Any])
            let actionID = action["id"] as? String ?? ""
            guard let target = Self.keys[action["target"] as? String ?? ""], let slot = Self.slots[actionID] else {
                failures.append("MATRIX \(id): no target or slot")
                continue
            }
            let creates = Self.creates.contains(actionID)
            let seeded = ["k1", "k2", "k3"]
            let (services, bridge) = try Self.sidebar(listing: creates ? seeded + ["k4"] : seeded, rowed: seeded, mixedOrder: mixedOrder)
            guard Self.order(bridge).filter({ $0 != "k4" }) == seeded else {
                failures.append("MATRIX \(id): seeded order \(Self.order(bridge)), expected \(seeded)")
                continue
            }
            let moving = creates ? "k4" : target
            let workspace = try #require(services.machines.local.store.workspaces.first { $0.id == moving })
            guard WorkspaceVerbHandlers.place(workspace, slot(target), in: bridge, services: services) else {
                failures.append("MATRIX \(id): the sidebar does not list \(moving)")
                continue
            }
            let expects = item["expect"] as? [[String: Any]] ?? []
            for expect in expects where expect["code"] as? String == "order-is" && expect["of"] as? String == "workspaces" {
                let wanted = (expect["ids"] as? [String] ?? []).map { Self.keys[$0] ?? $0 }
                let actual = Self.order(bridge)
                if actual != wanted { failures.append("MATRIX \(id): order-is \(actual), expected \(wanted)") }
            }
        }
        #expect(failures.isEmpty, "\(failures.count) sidebar-order cases failed (mixed order \(mixedOrder)):\n\(failures.joined(separator: "\n"))")
    }
}

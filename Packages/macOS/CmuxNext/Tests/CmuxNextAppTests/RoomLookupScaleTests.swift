import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Switching at scale (Lawrence 2026-10-28, switch-scale.md): every workspace select asks which room the workspace
/// is in (`WindowManager.select` -> `enterProfile(of:)` -> `WindowProfiles.room(of:)`), and every space switch which
/// workspaces its room shows (`WindowProfiles.visible`). Both made the room rules from scratch each time, a
/// dictionary of every pin of the home session: O(workspaces) per switch. The rules now come from the index the
/// personal store keeps with its pins, so a lookup costs the same with 20 workspaces as with 2,000.
@MainActor @Suite(.serialized)
struct RoomLookupScaleTests {
    static let session = "s-local"
    static let rooms = (0..<10).map { ProfileID(rawValue: "room\($0)") }

    /// A store of `total` workspaces, workspace i pinned to room i % 10 (`pins` overrides single pins).
    static func services(_ total: Int, pins overrides: [Int: ProfileID] = [:]) throws -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["profiles-v1","personal-mixed-order-v1"]}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree(total, overrides: overrides))
        return services
    }

    static func tree(_ total: Int, overrides: [Int: ProfileID] = [:], revision: UInt64 = 1) -> DaemonTree {
        let keys = (0..<total).map { "k\($0)" }
        var tree = DaemonTree(registryID: session, workspaces: keys.enumerated().map { index, key in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: "Workspace \(index)")
        })
        tree.personal = PersonalState(
            revision: revision,
            sessions: [SessionRecord(id: session)],
            profiles: rooms.enumerated().map { ProfileSnapshot(id: $1, name: "Space \($0)", index: $0) },
            pins: keys.enumerated().map { WorkspacePin(sessionID: session, workspaceKey: WorkspaceKey(rawValue: $1),
                                                       profile: overrides[$0] ?? rooms[$0 % rooms.count]) },
            workspaces: keys.enumerated().map { PersonalWorkspace(sessionID: session, workspaceKey: WorkspaceKey(rawValue: $1), index: $0) })
        return tree
    }

    /// Mean microseconds of one `room(of:)` (a workspace select's room lookup), over `calls` lookups.
    static func lookupCost(_ total: Int, calls: Int = 4_000) throws -> Double {
        let services = try Self.services(total)
        let machines = services.machines
        let ids = machines.local.store.workspaces.map(\.id)
        var found = 0
        for id in ids.prefix(50) where WindowProfiles.room(of: id, current: rooms[0], machines: machines) != nil { found += 1 }  // warm
        let start = ContinuousClock.now
        for call in 0..<calls where WindowProfiles.room(of: ids[call % ids.count], current: rooms[0], machines: machines) != nil { found += 1 }
        let elapsed = ContinuousClock.now - start
        #expect(found > 0)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return seconds * 1e6 / Double(calls)
    }

    /// The best of 5 runs per size, so one preemption of a loaded host cannot fail it: before the index a lookup at
    /// 2,000 workspaces cost about 100x the one at 20 (a dictionary of every pin per call).
    @Test func aRoomLookupCostsTheSameWith2000WorkspacesAsWith20() throws {
        let small = try (0..<5).map { _ in try Self.lookupCost(20) }.min() ?? 0
        let large = try (0..<5).map { _ in try Self.lookupCost(2_000) }.min() ?? 0
        print(String(format: "ROOM-LOOKUP us/call n=20 %.2f n=2000 %.2f", small, large))
        #expect(large <= small * 4 + 3, "a room lookup took \(large) us with 2,000 workspaces vs \(small) us with 20")
    }

    /// The index answers what the pins say, after a change too.
    @Test func theIndexFollowsThePins() throws {
        let services = try Self.services(30)
        let machines = services.machines
        let id = try #require(machines.local.store.workspaces.first { $0.key?.rawValue == "k3" }?.id)
        #expect(WindowProfiles.room(of: id, current: Self.rooms[0], machines: machines) == Self.rooms[3])
        #expect(WindowProfiles.room(of: id, current: Self.rooms[3], machines: machines) == nil, "already in the current room")
        #expect(WindowProfiles.visible([id], profile: Self.rooms[3], machines: machines) == [id])
        #expect(WindowProfiles.visible([id], profile: Self.rooms[4], machines: machines).isEmpty)

        machines.local.store.apply(snapshot: Self.tree(30, overrides: [3: Self.rooms[7]], revision: 2))
        #expect(WindowProfiles.room(of: id, current: Self.rooms[0], machines: machines) == Self.rooms[7])
        #expect(WindowProfiles.visible([id], profile: Self.rooms[3], machines: machines).isEmpty)
        #expect(WindowProfiles.visible([id], profile: Self.rooms[7], machines: machines) == [id])
        let qualified = try #require(WindowProfiles.qualified(id, machines: machines))
        #expect(WindowProfiles.membership(machines)?.rooms(of: qualified) == [Self.rooms[7]])
    }
}

import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextRemote
import CmuxNextWakeups
import Foundation
import Testing

/// What finding a workspace by its public id (`ws_…`) costs across every machine, and that the indexed lookup finds what
/// the walk found. Leo 2026-11-27: "maybe we ought to optimize our ds & a for our tooling + whatever stuff wrt the
/// rendering of the app and whatnot". A deep link, a Home link preview card and a group link each built
/// `MachineRegistry.allWorkspaces` (a fresh array of every workspace on every machine) and scanned it by resourceID; now
/// `daemons.workspace(resourceID:)` probes each store's resource index, so a lookup at 11,000 workspaces must
/// cost at most 4 times one at 110.
@MainActor @Suite(.serialized) struct MachineWorkspaceResourceLookupBenchTests {
    static let sizes = [110, 1100, 11000]
    static let lookups = 2000
    static let chief = try! ServerReach.localChief(homeID: "5a1dc0de", socket: "/tmp/cn-resource-lookup.sock", name: "Chief")

    static func resource(_ n: Int) -> String { String(format: "ws_%032d", n) }

    static func snapshot(_ handle: Int, resource: String?) -> WorkspaceSnapshot {
        WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(handle)), key: nil, resourceID: resource.map { ResourceID(rawValue: $0) },
                          name: "w\(handle)")
    }

    /// This Mac's daemon plus one other machine's (a local Chief server session), each holding `local` and `remote`.
    static func registry(local: [WorkspaceSnapshot], remote: [WorkspaceSnapshot]) -> MachineRegistry {
        _ = NSApplication.shared
        let machines = MachineRegistry(local: DaemonService())
        let session = ServerMachineSession(reach: chief, binary: nil, paths: .init(root: URL(fileURLWithPath: "/private/tmp/cn-resource-lookup-unused")),
                                           environment: { [:] }, localIdentity: { nil }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        machines.add(session)
        machines.local.store.apply(snapshot: DaemonTree(workspaces: local))
        session.daemon.store.apply(snapshot: DaemonTree(registryID: "cmux-chief-5a1dc0de", workspaces: remote))
        return machines
    }

    /// The lookup this replaced, as the callers wrote it.
    static func walk(_ machines: MachineRegistry, _ id: String) -> (WorkspaceModel, DaemonService)? {
        machines.allWorkspaces.first { $0.0.resourceID?.rawValue == id }
    }

    static func microseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds &- start) / 1000
    }

    static func stat(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
    }

    /// Per lookup (us) of random listed ids among `count` workspaces, all but a tenth on this Mac.
    static func cost(_ count: Int, _ lookup: (MachineRegistry, String) -> (WorkspaceModel, DaemonService)?) -> [Double] {
        let remote = count / 10
        let machines = registry(local: (remote..<count).map { snapshot($0 + 1, resource: resource($0)) },
                                remote: (0..<remote).map { snapshot($0 + 1, resource: resource($0)) })
        var rng = ResourceLookupRNG(7)
        let ids = (0..<lookups).map { _ in resource(Int(rng.next() % UInt64(count))) }
        return ids.map { id in microseconds { _ = lookup(machines, id) } }
    }

    @Test func lookupCostIsFlatAsWorkspacesGrow() {
        _ = Self.cost(110) { $0.daemons.workspace(resourceID: $1) }
        var p50: [Int: Double] = [:]
        for count in Self.sizes {
            let walk = Self.cost(count, Self.walk), index = Self.cost(count) { $0.daemons.workspace(resourceID: $1) }
            p50[count] = Self.stat(index, 0.5)
            print(String(format: "MACHINE-RESOURCE-LOOKUP-COST workspaces=%d walk p50=%.2fus p95=%.2fus | index p50=%.2fus p95=%.2fus",
                         count, Self.stat(walk, 0.5), Self.stat(walk, 0.95), Self.stat(index, 0.5), Self.stat(index, 0.95)))
        }
        let small = max(p50[110] ?? 0, 0.5), large = p50[11000] ?? 0
        #expect(large <= 4 * small, "a lookup at 11,000 workspaces cost \(large)us, over 4x the \(small)us at 110")
    }

    /// The oracle: on random machines (ids on both machines, workspaces with no public id, ids no workspace has, and a
    /// snapshot that moves public ids between workspaces in place), the indexed lookup returns the same workspace on the
    /// same machine as the walk of every workspace, local first. Public ids are unique within one machine, as the
    /// daemon issues them.
    @Test func lookupMatchesTheWalk() {
        for seed in 1...40 {
            var rng = ResourceLookupRNG(UInt64(seed))
            func pick(_ pool: Int) -> [WorkspaceSnapshot] {
                var ids = Array(0..<pool)
                for i in ids.indices.reversed() { ids.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
                let count = Int(rng.next() % UInt64(pool / 2 + 1))
                return ids.prefix(count).enumerated().map { handle, n in
                    Self.snapshot(handle + 1, resource: rng.next() % 5 == 0 ? nil : Self.resource(n))
                }
            }
            let pool = 8 + Int(rng.next() % 40)
            let machines = Self.registry(local: pick(pool), remote: pick(pool))
            func check(_ phase: String) {
                for n in 0..<(pool + 4) {
                    let id = Self.resource(n), found = machines.daemons.workspace(resourceID: id), walked = Self.walk(machines, id)
                    #expect(found?.0 === walked?.0 && found?.1 === walked?.1, "seed \(seed) \(phase): \(id)")
                }
            }
            check("first snapshot")
            machines.local.store.apply(snapshot: DaemonTree(workspaces: pick(pool)))
            check("after the ids moved")
        }
    }
}

struct ResourceLookupRNG {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

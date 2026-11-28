@testable import CmuxNextSidebar
import Foundation
import Testing

/// What `SidebarModel.workspace(_:)` costs, and that it finds what the walk of every row found.
/// Leo 2026-11-27: "maybe we ought to optimize our ds & a for our tooling + whatever stuff wrt the rendering of the app
/// and whatnot". A drag reads the dragged rows and their parent chains through it on every move, hover cards and row
/// menus once per show. It walked every section, node and group member (`SidebarEdits.workspace`), so one lookup of the
/// last row cost the whole list; now it reads `rowIndex`, and a lookup at 11,000 rows must cost at most 4 times one at 110.
@MainActor @Suite(.serialized) struct SidebarWorkspaceLookupCostTests {
    static let sizes = [110, 1100, 11000]
    static let lookups = 2000

    /// `count` workspaces: every third one loose, the rest in groups of 8, across two machine sections.
    static func sections(_ count: Int, seed: UInt64 = 1) -> [SidebarSection] {
        var rng = LookupRNG(seed)
        var nodes: [[SidebarNode]] = [[], []]
        var next = 0
        while next < count {
            let s = Int(rng.next() % 2)
            if rng.next() % 3 == 0 {
                nodes[s].append(.workspace(SidebarWorkspace(id: WorkspaceID("wl-\(next)"), title: "w\(next)")))
                next += 1
            } else {
                let end = min(count, next + 1 + Int(rng.next() % 8))
                nodes[s].append(.group(SidebarGroup(id: GroupID("wl-g\(next)"), name: "g\(next)", color: .green,
                                                    workspaces: (next..<end).map { SidebarWorkspace(id: WorkspaceID("wl-\($0)"), title: "w\($0)") })))
                next = end
            }
        }
        let machines = [SidebarMachine(id: .local, name: "This Mac", kind: .local),
                        SidebarMachine(id: MachineID("other"), name: "Other", kind: .ssh)]
        return zip(machines, nodes).map { SidebarSection(kind: .machine($0), nodes: $1) }
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

    /// Per lookup (us) of random listed ids, through `lookup`.
    static func cost(_ count: Int, _ lookup: (SidebarModel, [SidebarSection], WorkspaceID) -> SidebarWorkspace?) -> [Double] {
        let sections = sections(count)
        let model = SidebarModel(sections: sections)
        _ = model.workspace(WorkspaceID("wl-0")) // the index is built once per structural set, not per lookup
        var rng = LookupRNG(7)
        let ids = (0..<lookups).map { _ in WorkspaceID("wl-\(rng.next() % UInt64(count))") }
        return ids.map { id in microseconds { _ = lookup(model, sections, id) } }
    }

    @Test func lookupCostIsFlatAsRowsGrow() {
        _ = Self.cost(110) { m, _, id in m.workspace(id) }
        var p50: [Int: Double] = [:]
        for count in Self.sizes {
            let walk = Self.cost(count) { _, s, id in SidebarEdits.workspace(id, in: s) }
            let index = Self.cost(count) { m, _, id in m.workspace(id) }
            p50[count] = Self.stat(index, 0.5)
            print(String(format: "WORKSPACE-LOOKUP-COST rows=%d walk p50=%.2fus p95=%.2fus | index p50=%.2fus p95=%.2fus",
                         count, Self.stat(walk, 0.5), Self.stat(walk, 0.95), Self.stat(index, 0.5), Self.stat(index, 0.95)))
        }
        let small = p50[110] ?? 0, large = p50[11000] ?? .infinity
        #expect(large <= max(small, 0.5) * 4, "a lookup at 11,000 rows costs \(large)us, at 110 rows \(small)us")
    }

    /// The old walk is the oracle: on random sections (a workspace listed twice, ids no row has, row patches and
    /// structural sets between lookups) the indexed lookup returns the same row.
    @Test func lookupMatchesTheWalk() {
        for seed in 1...40 as ClosedRange<UInt64> {
            var rng = LookupRNG(seed &* 31)
            var sections = Self.sections(Int(rng.next() % 60) + 1, seed: seed)
            if let first = sections[0].nodes.first, case let .workspace(ws) = first { // listed twice
                sections[1].nodes.append(.workspace(SidebarWorkspace(id: ws.id, title: "twin")))
            }
            let model = SidebarModel(sections: sections)
            for step in 0..<30 {
                let count = model.sections.flatMap(\.workspaces).count + 3
                let id = WorkspaceID("wl-\(rng.next() % UInt64(max(count, 1)))")
                #expect(model.workspace(id) == SidebarEdits.workspace(id, in: model.sections), "seed \(seed) step \(step) id \(id)")
                switch rng.next() % 3 {
                case 0: // a row patch: same places, new content
                    if var row = model.workspace(id) { row.title += "*"; _ = model.patchWorkspaces([row]) }
                case 1: // a structural set: drop one node
                    var next = model.sections
                    let s = Int(rng.next() % UInt64(next.count))
                    if !next[s].nodes.isEmpty { next[s].nodes.remove(at: Int(rng.next() % UInt64(next[s].nodes.count))) }
                    model.sections = next
                default: break
                }
            }
        }
    }
}

/// A small seeded generator, so a failure names a seed that reproduces it.
struct LookupRNG {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

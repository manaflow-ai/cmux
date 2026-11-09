@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-11-04: "never ... acceptable ... linear time growth degradation". One row's content change from the
/// feed (a title, a branch, an agent step) costs `SidebarRows.patch` the same at 3,000 workspaces as at 100: before,
/// every patch walked every section and node of the live rows and copied them (`SidebarSection.patching`).
@MainActor @Suite(.serialized)
struct SidebarRowsPatchCostTests {
    /// `count` workspaces on this Mac, in groups of 25 with every fifth group's rows loose.
    static func sections(_ count: Int) -> [CmuxNextSidebar.SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let rows = (0..<count).map { SidebarWorkspace(id: WorkspaceID("w\($0)"), title: "w\($0)", branch: "b0") }
        var nodes: [SidebarNode] = []
        for (g, start) in stride(from: 0, to: count, by: 25).enumerated() {
            let members = Array(rows[start..<min(count, start + 25)])
            if g % 5 == 4 { nodes += members.map { .workspace($0) }; continue }
            nodes.append(.group(SidebarGroup(id: GroupID("g\(g)"), name: "g\(g)", color: .blue, workspaces: members)))
        }
        return [SidebarSection(kind: .machine(machine), nodes: nodes)]
    }

    private static func row(_ id: String, in model: SidebarModel) -> SidebarWorkspace? {
        model.sections.flatMap(\.workspaces).first { $0.id == WorkspaceID(id) }
    }

    @Test func aPatchWritesItsRowsAndKeepsTheirRowStateThroughLaterShows() {
        let model = SidebarModel(sections: [])
        let shown = SidebarRows(model: model, document: { nil })
        var start = Self.sections(60)
        if case var .group(group) = start[0].nodes[0] {
            group.workspaces[3].rowState = .stale
            start[0].nodes[0] = .group(group)
        }
        shown.show(start)
        var changed = start[0].workspaces[3]
        changed.rowState = .live
        changed.branch = "b1"
        var loose = Self.sections(60)[0].workspaces[45]
        loose.branch = "b2"
        shown.patch([changed, loose])
        #expect(Self.row("w3", in: model)?.branch == "b1")
        #expect(Self.row("w3", in: model)?.rowState == .stale, "a patch keeps the listed row's state")
        #expect(Self.row("w45", in: model)?.branch == "b2")
        // A structural pass that lists the same rows again keeps nothing stale from the patched copy.
        shown.show(Self.sections(61))
        #expect(Self.row("w60", in: model) != nil)
        var later = Self.sections(61)[0].workspaces[60]
        later.branch = "b3"
        shown.patch([later])
        #expect(Self.row("w60", in: model)?.branch == "b3")
        #expect(Self.row("w3", in: model)?.branch == "b0", "the new rows replaced the patched ones")
    }

    /// Nanoseconds per `SidebarRows.patch` of one row over `count` workspaces, best of three rounds.
    static func patchCost(_ count: Int, patches: Int = 400) -> Double {
        let rows = SidebarRows(model: SidebarModel(sections: []), document: { nil })
        let start = sections(count)
        rows.show(start)
        let target = start[0].workspaces[count / 2]
        var best = Double.infinity
        for round in 0..<3 {
            let begin = DispatchTime.now().uptimeNanoseconds
            for i in 0..<patches {
                var row = target
                row.branch = "b\(round * patches + i + 1)"
                rows.patch([row])
            }
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - begin) / Double(patches))
        }
        return best
    }

    @Test func oneRowsPatchCostsTheSameAt3000WorkspacesAsAt100() {
        _ = Self.patchCost(100, patches: 50) // warm up
        let small = Self.patchCost(100)
        let mid = Self.patchCost(1000)
        let large = Self.patchCost(3000)
        print("sidebar-rows-patch-cost ns/patch N=100 \(Int(small)) N=1000 \(Int(mid)) N=3000 \(Int(large))")
        // Constant cost: well under the 30x a walk of every row would give (measured before: see the pull request).
        #expect(large < small * 4, "one row's patch at 3,000 workspaces took \(Int(large)) ns, at 100 \(Int(small)) ns")
    }
}

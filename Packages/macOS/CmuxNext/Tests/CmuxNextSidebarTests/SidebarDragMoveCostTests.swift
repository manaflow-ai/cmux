import CoreGraphics
@testable import CmuxNextSidebar
import Foundation
import Testing

/// What one drag move costs the main thread, as `SidebarListView.updateDrag` runs it: the check that the drag's base
/// layout and drop rules still hold (`SidebarListView.dragBase`, made once per drag), the drop resolve in the shared
/// Rust reducer (`DropResolver.DragRules`) and the probe's base y (`DropResolver.baseY`).
/// Leo 2026-11-06: rendering paths "we measured as being better in swift than in rust bc our apis or whatever were
/// adding overhead... but tbh i feel like we can potentially do better there". A move crosses into Rust; the
/// crossing must not grow with the rows the sidebar holds.
///
/// The harness lists `count` workspaces in groups of 10 in one machine section and sweeps a lifted card from the
/// top of the list to the bottom in 200 moves. It prints, per size, the median and p95 of one move and of each part
/// (`DRAG-MOVE-COST` lines).
/// Before the drag handle each move laid the list out and sent every row to Rust as JSON (rows=5000: about 100 times
/// the cost of rows=50); now a move at 5,000 rows must cost at most 4 times one at 50.
@MainActor @Suite(.serialized) struct SidebarDragMoveCostTests {
    static let sizes = [50, 200, 1000, 5000]
    static let moves = 200

    static func sections(_ count: Int) -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let groups = stride(from: 0, to: count, by: 10).map { start in
            SidebarNode.group(SidebarGroup(id: GroupID("dc-g\(start)"), name: "Group \(start)", color: .green,
                                           workspaces: (start..<min(count, start + 10)).map {
                                               SidebarWorkspace(id: WorkspaceID("dc-\($0)"), title: "workspace \($0)")
                                           }))
        }
        return [SidebarSection(kind: .machine(machine), nodes: groups)]
    }

    struct Cost: CustomStringConvertible {
        var move: [Double] = [], layout: [Double] = [], resolve: [Double] = [], baseY: [Double] = []
        static func stat(_ values: [Double], _ q: Double) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
        }
        var median: Double { Self.stat(move, 0.5) }
        var description: String {
            String(format: "move p50=%.1fus p95=%.1fus | layout p50=%.1fus | resolve p50=%.1fus | baseY p50=%.1fus",
                   Self.stat(move, 0.5), Self.stat(move, 0.95), Self.stat(layout, 0.5), Self.stat(resolve, 0.5),
                   Self.stat(baseY, 0.5))
        }
    }

    static func microseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds &- start) / 1000
    }

    /// One sweep of `moves` drag moves over `count` workspaces, the dragged one being the first.
    static func sweep(_ count: Int) -> Cost {
        let sections = sections(count)
        let metrics = SidebarLayoutMetrics.standard
        let options = SidebarLayoutOptions()
        let payload = DragPayload.workspaces([WorkspaceID("dc-0")])
        let height = SidebarLayout.make(sections: sections, metrics: metrics, options: options).totalHeight
        var cost = Cost()
        let key = SidebarDragBaseKey(content: 1, reloads: 1, width: 260, metrics: metrics, ungroupedFirst: false)
        let base = SidebarLayout.make(sections: sections, metrics: metrics, options: options)
        var made: (key: SidebarDragBaseKey, layout: SidebarLayout, rules: DropResolver.DragRules?)? = (key, base,
            DropResolver.DragRules(payload: payload, base: base, sections: sections))
        for step in 0..<moves {
            let centre = height * CGFloat(step) / CGFloat(moves)
            var rules: DropResolver.DragRules?
            var resolved: (target: DropTarget?, probe: DropResolver.DragProbe)?
            let move = microseconds {
                cost.layout.append(microseconds {
                    let now = SidebarDragBaseKey(content: 1, reloads: 1, width: 260, metrics: metrics, ungroupedFirst: false)
                    if made?.key != now { made = nil }
                    rules = made?.rules
                })
                cost.resolve.append(microseconds {
                    resolved = rules?.resolve(centreY: centre, leadingY: centre + 14, gapY: nil, gapHeight: 28)
                })
                cost.baseY.append(microseconds { _ = DropResolver.baseY(forDisplayY: centre, gapY: nil, gapHeight: 28) })
            }
            cost.move.append(move)
            _ = resolved
        }
        return cost
    }

    @Test func dragMoveCostPerSize() {
        _ = Self.sweep(50) // warm the reducer and the allocator
        var medians: [Int: Double] = [:]
        for count in Self.sizes {
            let cost = Self.sweep(count)
            medians[count] = cost.median
            print("DRAG-MOVE-COST rows=\(count) \(cost)")
        }
        let small = medians[50] ?? 0, large = medians[5000] ?? .infinity
        #expect(large <= max(small, 1) * 4, "a drag move at 5,000 rows costs \(large)us, at 50 rows \(small)us")
    }
}

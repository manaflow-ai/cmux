@testable import CmuxNextSidebar
import Foundation
import Testing

/// One order for every reader (sidebar owner, 2026-10-24): after a move, tab search and `window list` showed a stale
/// order because each kept its own copy. `SidebarModel.workspaceOrder` is the window's listed order with each
/// workspace's position and neighbours: a move updates it with one build, and any number of lookups after it cost
/// no walk of the rows.
@MainActor @Suite(.serialized) struct SidebarWorkspaceOrderTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    /// 40 loose workspaces, then 8 groups of 45 (400 in all), in `order`.
    static func sections(_ order: [WorkspaceID]) -> [SidebarSection] {
        let rows = order.map { SidebarWorkspace(id: $0, title: $0.rawValue) }
        var nodes: [SidebarNode] = rows[..<40].map { .workspace($0) }
        for g in 0..<8 {
            nodes.append(.group(SidebarGroup(id: GroupID("g\(g)"), name: "Group \(g)", color: .green,
                                             workspaces: Array(rows[(40 + g * 45)..<(40 + g * 45 + 45)]))))
        }
        return [SidebarSection(kind: .machine(machine), nodes: nodes)]
    }

    static func builds(_ body: () -> Void) -> Int {
        _ = SidebarPerfCounters.report(reset: true)
        body()
        return SidebarPerfCounters.report(reset: true)["order_builds"] ?? 0
    }

    @Test func aMoveUpdatesTheOrderWithOneBuildAndLookupsCostNone() {
        var order = (0..<400).map { WorkspaceID(String(format: "w%03d", $0)) }
        let model = SidebarModel(sections: Self.sections(order), activeWorkspaceID: nil)
        #expect(Self.builds { _ = model.workspaceOrder } == 1)
        #expect(model.workspaceOrder.position(of: WorkspaceID("w377")) == 377)

        // `workspace move --index 0`: w377 goes to the top.
        order.insert(order.remove(at: 377), at: 0)
        model.sections = Self.sections(order)
        let moved = WorkspaceID("w377")
        var lookups = 0
        let built = Self.builds {
            for id in order {
                _ = model.workspaceOrder.position(of: id)
                _ = model.workspaceOrder.neighbours(of: id)
                lookups += 2
            }
        }
        #expect(built == 1, "\(lookups) lookups after one move built the order \(built) times")
        #expect(model.workspaceOrder.position(of: moved) == 0)
        #expect(model.workspaceOrder.neighbours(of: moved)?.above == nil)
        #expect(model.workspaceOrder.neighbours(of: moved)?.below == WorkspaceID("w000"))
        #expect(model.workspaceOrder.neighbours(of: WorkspaceID("w376"))?.below == WorkspaceID("w378"))
        #expect(model.workspaceOrder == SidebarWorkspaceOrder(model.sections), "the order differs from one built fresh")
        #expect(model.workspaceOrder.ids == model.allWorkspaces.map(\.id))
        #expect(model.workspaceOrder.position(of: WorkspaceID("not-listed")) == nil)
    }

    /// A row's content patch (a status tick) moves no row: the order is not built again.
    @Test func aRowPatchKeepsTheOrder() {
        let order = (0..<400).map { WorkspaceID(String(format: "w%03d", $0)) }
        let model = SidebarModel(sections: Self.sections(order), activeWorkspaceID: nil)
        _ = model.workspaceOrder
        let built = Self.builds {
            _ = model.patchWorkspaces([SidebarWorkspace(id: WorkspaceID("w123"), title: "w123", status: "Running")])
            _ = model.workspaceOrder.position(of: WorkspaceID("w123"))
        }
        #expect(built == 0)
    }
}

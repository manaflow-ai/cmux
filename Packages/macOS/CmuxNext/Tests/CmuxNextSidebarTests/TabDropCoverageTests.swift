import CoreGraphics
import Testing
@testable import CmuxNextSidebar

/// tab-dnd (coordinator decision 2026-10-04: the outline at every point,
/// in the sidebar too). Every y of the sidebar list, above and below its
/// rows included, resolves to a drop slot or to a refusal with its row, so
/// the sidebar never shows nothing while a tab is over it.
@Suite struct TabDropCoverageTests {
    let sections = fixture()
    var base: SidebarLayout { SidebarLayout.make(sections: sections, metrics: .standard) }

    @Test func everyYResolvesToASlotOrARefusal() {
        let layout = base
        let bottom = (layout.rows.last?.maxY ?? 0) + 40
        for machine in [MachineID.local, cloud] {
            var y: CGFloat = -20
            while y < bottom {
                let drop = DropResolver.resolveTabDrop(y: y, base: layout, sections: sections, sourceMachine: machine)
                let refusal = DropResolver.tabDropRefusal(y: y, base: layout, sections: sections, sourceMachine: machine)
                #expect((drop == nil) != (refusal == nil), "y \(y) machine \(machine): drop \(String(describing: drop)) refusal \(String(describing: refusal))")
                y += 2
            }
        }
    }

    @Test func refusalsNameTheirReason() {
        let x = base.row(for: .workspace(id("x")))!
        #expect(DropResolver.tabDropRefusal(y: x.y + x.height / 2, base: base, sections: sections, sourceMachine: .local)?.reason
            == .otherMachine)
        let p1 = base.row(for: .workspace(id("p1")))!
        #expect(DropResolver.tabDropRefusal(y: p1.y + p1.height * 0.1, base: base, sections: sections, sourceMachine: .local)?.reason
            == .pinnedArea)
    }
}

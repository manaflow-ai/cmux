import AppKit
import Testing
@testable import CmuxNextSidebar

/// A double-click on empty sidebar space makes a new workspace there: below
/// the last row at the end, inside an expanded group's empty part at the
/// end of that group. A double-click on a row keeps its meaning (rename).
@MainActor @Suite struct EmptyAreaDoubleClickTests {
    static let metrics = SidebarLayoutMetrics.standard

    /// local: a, G1{g1,g2,g3}, b, G2(collapsed){h1,h2}, c; then a cloud section.
    static func layout(_ sections: [SidebarSection] = Array(fixture().dropFirst())) -> SidebarLayout {
        SidebarLayout.make(sections: sections, metrics: metrics)
    }

    static func y(below key: SidebarRowKey, in layout: SidebarLayout, by offset: CGFloat = 1) -> CGFloat {
        layout.row(for: key)!.maxY + offset
    }

    @Test func belowTheLastRowIsTheEndOfItsSection() {
        let layout = Self.layout()
        let target = layout.emptyAreaTarget(at: layout.totalHeight - 1, metrics: Self.metrics)
        #expect(target == SidebarEmptyAreaTarget(section: cloudSection, group: nil))
    }

    @Test func farBelowTheListIsTheEnd() {
        let layout = Self.layout()
        #expect(layout.emptyAreaTarget(at: layout.totalHeight + 400, metrics: Self.metrics)
            == SidebarEmptyAreaTarget(section: cloudSection, group: nil))
    }

    @Test func theEmptyPartBelowAGroupsLastMemberIsThatGroup() {
        let layout = Self.layout()
        let y = Self.y(below: .workspace(id("g3")), in: layout)
        #expect(layout.row(at: y) == nil)
        #expect(layout.emptyAreaTarget(at: y, metrics: Self.metrics) == SidebarEmptyAreaTarget(section: local, group: g1))
    }

    @Test func theSpacingBetweenGroupMembersIsThatGroup() {
        let layout = Self.layout()
        let y = Self.y(below: .workspace(id("g1")), in: layout, by: 0.5)
        guard layout.row(at: y) == nil else { return }
        #expect(layout.emptyAreaTarget(at: y, metrics: Self.metrics) == SidebarEmptyAreaTarget(section: local, group: g1))
    }

    @Test func theSpacingBelowALooseRowIsTheSectionEnd() {
        let layout = Self.layout()
        let y = Self.y(below: .workspace(id("a")), in: layout, by: 0.5)
        guard layout.row(at: y) == nil else { return }
        #expect(layout.emptyAreaTarget(at: y, metrics: Self.metrics) == SidebarEmptyAreaTarget(section: local, group: nil))
    }

    @Test func belowACollapsedGroupIsNotInsideIt() {
        let layout = Self.layout()
        let y = Self.y(below: .group(g2), in: layout, by: 0.5)
        guard layout.row(at: y) == nil else { return }
        #expect(layout.emptyAreaTarget(at: y, metrics: Self.metrics) == SidebarEmptyAreaTarget(section: local, group: nil))
    }

    @Test func belowAnEmptyExpandedGroupIsThatGroup() {
        let machine = SidebarMachine(id: .local, name: "Local", kind: .local)
        let empty = GroupID("E")
        let layout = Self.layout([SidebarSection(kind: .machine(machine), nodes: [
            .workspace(w("a")), .group(SidebarGroup(id: empty, name: "E", workspaces: [])),
        ])])
        let y = Self.y(below: .group(empty), in: layout)
        #expect(layout.emptyAreaTarget(at: y, metrics: Self.metrics) == SidebarEmptyAreaTarget(section: local, group: empty))
        // Past the group's own bottom padding the list ends: a loose workspace.
        #expect(layout.emptyAreaTarget(at: layout.totalHeight + 40, metrics: Self.metrics) == SidebarEmptyAreaTarget(section: local, group: nil))
    }

    @Test func onARowIsNoTarget() {
        let layout = Self.layout()
        let row = layout.row(for: .workspace(id("b")))!
        #expect(layout.emptyAreaTarget(at: row.y + 1, metrics: Self.metrics) == nil)
    }

    // MARK: The list view

    final class Harness {
        let window: NSWindow
        let sidebar: SidebarView
        var intents: [SidebarIntent] = []

        init(sections: [SidebarSection] = Array(fixture().dropFirst()), height: CGFloat = 900) {
            let model = SidebarModel(sections: sections, activeWorkspaceID: id("a"))
            sidebar = SidebarView(model: model)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: height), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            sidebar.frame = window.contentView!.bounds
            window.contentView!.addSubview(sidebar)
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
            model.onIntent = { [unowned self] intent in self.intents.append(intent) }
        }

        var list: SidebarListView { sidebar.list }

        func point(y: CGFloat) -> NSPoint { list.convert(NSPoint(x: 60, y: y), to: nil) }

        func click(_ point: NSPoint, count: Int) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                               clickCount: count, pressure: 1)!
                if type == .leftMouseDown { list.mouseDown(with: event) } else { list.mouseUp(with: event) }
            }
        }

        var newWorkspaces: [SidebarIntent] {
            intents.filter { if case .newWorkspace = $0 { true } else { false } }
        }
    }

    @Test func doubleClickBelowTheLastRowAsksForANewWorkspaceAtTheEnd() {
        let h = Harness()
        let point = h.point(y: h.list.displayed.totalHeight + 20)
        h.click(point, count: 1)
        #expect(h.newWorkspaces.isEmpty)
        h.click(point, count: 2)
        #expect(h.newWorkspaces == [.newWorkspace(machine: cloud, group: nil)])
    }

    @Test func doubleClickInAGroupsEmptyPartAsksForANewWorkspaceInThatGroup() {
        let h = Harness()
        let y = Self.y(below: .workspace(id("g3")), in: h.list.displayed)
        h.click(h.point(y: y), count: 2)
        #expect(h.newWorkspaces == [.newWorkspace(machine: .local, group: g1)])
    }

    @Test func doubleClickOnARowStillRenames() {
        let h = Harness()
        let row = h.list.displayed.row(for: .workspace(id("b")))!
        h.click(h.point(y: row.y + row.height / 2), count: 2)
        #expect(h.newWorkspaces.isEmpty)
        #expect(h.list.rename?.key == .workspace(id("b")))
        h.list.endRename(commit: false)
    }
}

import AppKit
import Testing
@testable import CmuxNextSidebar

/// Spec amendment 1780d02 (`centre band`, Lawrence via coordinator
/// 2026-10-06): a card held square on a loose workspace row groups with it,
/// so the 30-70% onto band is measured at the dragged card's centre. A loose
/// row makes way once the card centre passes 30% of it. nxdog57 dropped
/// square on a row and got a reorder.
@MainActor @Suite struct SidebarOntoCentreBandTests {
    func harness(_ sections: [SidebarSection], active: String) -> (SidebarModel, SidebarListView, NSWindow) {
        let model = SidebarModel(sections: sections, activeWorkspaceID: id(active))
        model.onIntent = { [weak model] intent in model?.apply(intent) }
        let sidebar = SidebarView(model: model)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 700, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        window.contentView?.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        return (model, sidebar.list, window)
    }

    /// Drags `from` (pressed at its middle) so the pointer, and so the
    /// card's centre, ends at `fraction` of `to`'s frame as first laid out.
    func drag(_ list: SidebarListView, from: String, to: String, fraction: CGFloat) throws {
        let source = list.frame(for: try #require(list.displayed.row(for: .workspace(id(from)))))
        let target = list.frame(for: try #require(list.displayed.row(for: .workspace(id(to)))))
        let press = NSPoint(x: source.minX + 40, y: source.midY)
        list.beginDrag(SidebarListView.Press(key: .workspace(id(from)), point: press))
        let goal = target.minY + target.height * fraction
        for step in 1...12 {
            let py = press.y + (goal - press.y) * CGFloat(step) / 12
            list.updateDrag(windowPoint: list.convert(NSPoint(x: press.x, y: py), to: nil))
        }
    }

    func groups(_ model: SidebarModel, _ section: SectionID) -> [SidebarGroup] {
        model.sections.first { $0.id == section }?.nodes.compactMap { node in
            if case let .group(group) = node { return group }
            return nil
        } ?? []
    }

    @Test func aCardCentredOnALooseRowAboveGroupsWithIt() throws {
        let (model, list, window) = harness(fixture(), active: "a")
        defer { window.close() }
        let x = list.frame(for: try #require(list.displayed.row(for: .workspace(id("x")))))
        try drag(list, from: "y", to: "x", fraction: 0.5)
        #expect(list.drag?.target == .ontoWorkspace(id("x")))
        #expect(list.displayed.row(for: .workspace(id("x"))).map(list.frame(for:)) == x, "the target row holds still")
        list.finishDrag()
        let made = groups(model, model.sections[2].id)
        try #require(made.count == 1, "one new group: \(shape(model.sections, model.sections[2].id))")
        #expect(Set(made[0].workspaces.map(\.id)) == [id("x"), id("y")])
    }

    @Test func aCardCentredOnALooseRowBelowGroupsWithIt() throws {
        let (model, list, window) = harness(fixture(), active: "a")
        defer { window.close() }
        try drag(list, from: "x", to: "y", fraction: 0.5)
        #expect(list.drag?.target == .ontoWorkspace(id("y")))
        list.finishDrag()
        let made = groups(model, model.sections[2].id)
        try #require(made.count == 1, "one new group: \(shape(model.sections, model.sections[2].id))")
        #expect(Set(made[0].workspaces.map(\.id)) == [id("x"), id("y")])
    }

    /// The daemon refuses a group without a name ("group name cannot be
    /// empty"; sbmix-v4 GUI run): an onto-drop group gets a default name.
    @Test func anOntoDropGroupHasAName() throws {
        let (model, list, window) = harness(fixture(), active: "a")
        defer { window.close() }
        try drag(list, from: "y", to: "x", fraction: 0.5)
        list.finishDrag()
        let made = groups(model, model.sections[2].id)
        try #require(made.count == 1)
        #expect(!made[0].name.isEmpty, "the new group has a name")
    }

    /// Past the band: the card centre in the top 30% of the row above
    /// reorders, and the loose row makes way under the card.
    @Test func aCardCentrePastTheTopOfTheBandReorders() throws {
        let (model, list, window) = harness(fixture(), active: "a")
        defer { window.close() }
        try drag(list, from: "y", to: "x", fraction: 0.15)
        #expect(list.drag?.target != .ontoWorkspace(id("x")))
        list.finishDrag()
        #expect(groups(model, model.sections[2].id).isEmpty)
        #expect(shape(model.sections, model.sections[2].id) == "y x")
    }
}

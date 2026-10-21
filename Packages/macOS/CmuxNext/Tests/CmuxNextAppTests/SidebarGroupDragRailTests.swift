import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Sidebar sweep 2026-10-21 (build ef4dfa4f2f5): groups Work (3 members), Infra (`deploy`) and an empty group.
/// Dragging Infra's header down past the empty group and dropping it left `deploy` with no group rail (the members'
/// line). The rail stayed missing through theme changes and config reloads and came back only when a daemon move
/// rebuilt the list. Rule: once the card lands, every open group with members draws its rail, at its rows.
/// The drop runs through the sidebar document's drag (`SidebarModel.docDrag`), the path the app uses.
@MainActor @Suite(.serialized) struct SidebarGroupDragRailTests {
    static let section = "sec"
    static let work = GroupID("g-work"), infra = GroupID("g-infra"), empty = GroupID("g-empty")

    final class Drops {
        var targets: [SidebarDocTarget] = []
    }

    static func ws(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    static func sections(_ order: [GroupID]) -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let groups: [GroupID: SidebarGroup] = [
            work: SidebarGroup(id: work, name: "Work", color: .blue, workspaces: ["docs", "web", "api"].map(ws)),
            infra: SidebarGroup(id: infra, name: "Infra", color: .green, workspaces: [ws("deploy")]),
            empty: SidebarGroup(id: empty, name: "Empty group", color: .red, workspaces: []),
        ]
        return [SidebarSection(kind: .machine(machine), nodes: [.workspace(ws("scratch"))] + order.compactMap { groups[$0].map { .group($0) } })]
    }

    static func list(_ drops: Drops) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let model = SidebarModel(sections: sections([work, infra, empty]), activeWorkspaceID: WorkspaceID("scratch"))
        let members: Set<String> = ["docs", "web", "api", "deploy"]
        model.docDrag = SidebarDocDrag(item: { key in
            switch key {
            case let .workspace(id): "w_\(id.rawValue)"
            case let .group(group): "g_\(group.rawValue)"
            default: nil
            }
        }, section: { _ in section }, begin: { _ in
            var table: [String: SidebarDocAcceptance] = [section: SidebarDocAcceptance(before: false, into: true, after: false)]
            table["w_scratch"] = SidebarDocAcceptance(before: true, into: false, after: true)
            for group in [work, infra, empty] { table["g_\(group.rawValue)"] = SidebarDocAcceptance(before: true, into: false, after: true, refusal: nil) }
            for member in members { table["w_\(member)"] = SidebarDocAcceptance(before: false, into: false, after: false, refusal: "nesting") }
            return table
        }, drop: { [drops] _, target in drops.targets.append(target) })
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        return (list, window)
    }

    /// Each open group with members: its rail as the list draws it now (nil: none), and where its rows put it.
    static func rails(_ list: SidebarListView) -> [(group: GroupID, shown: (frame: CGRect, alpha: CGFloat)?, expected: CGRect)] {
        let expected = SidebarGroupLine.lines(list.displayed.rows, colors: list.groups) { list.frame(for: $0) }
        let shown = list.groupLineViews.shown
        return expected.map { ($0.group, shown[$0.group], $0.frame) }
    }

    static func describe(_ list: SidebarListView) -> String {
        let rows = list.displayed.rows.map { row -> String in
            "\(row.key)\(row.group.map { " in \($0.rawValue)" } ?? "")\(row.isCollapsed ? " (collapsed)" : "")"
        }
        return "rows \(rows); suppressed \(list.suppressed); lines \(list.groupLineViews.shown.keys.map(\.rawValue).sorted()); "
            + "settling \(list.settling != nil), landing \(list.landing != nil)"
    }

    /// Drags Infra's header down until the card's top is past the empty group's middle, then lets go.
    static func dragInfraPastEmpty(_ list: SidebarListView) throws {
        let header = try #require(list.displayed.row(for: .group(infra)))
        let emptyRow = try #require(list.displayed.row(for: .group(empty)))
        let start = NSPoint(x: 80, y: header.y + header.height / 2)
        list.press = SidebarPress(key: header.key, point: start)
        list.beginDrag(try #require(list.press))
        try #require(list.drag != nil, "the group did not lift")
        let dy = emptyRow.maxY + header.height - start.y
        for step in 1...6 {
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: start.y + dy * CGFloat(step) / 6), to: nil))
        }
        list.finishDrag()
    }

    /// The daemon's echo of the drop: the document's new order, shown as the app's model change shows it.
    static func echo(_ list: SidebarListView) {
        list.model.sections = sections([work, empty, infra])
        list.showModelChange(animates: true)
    }

    static func expectRails(_ list: SidebarListView, _ when: String) {
        let rails = rails(list)
        #expect(rails.map(\.group).contains(infra), "\(when): the layout has no Infra rail to draw: \(describe(list))")
        for rail in rails {
            guard let shown = rail.shown else {
                Issue.record("\(when): \(rail.group.rawValue) draws no rail: \(describe(list))")
                continue
            }
            #expect(shown.alpha == 1, "\(when): \(rail.group.rawValue)'s rail is see-through (\(shown.alpha))")
            #expect(abs(shown.frame.minY - rail.expected.minY) < 0.5 && abs(shown.frame.height - rail.expected.height) < 0.5,
                    "\(when): \(rail.group.rawValue)'s rail \(shown.frame) is not at its rows \(rail.expected)")
        }
    }

    /// The card lands before the daemon's echo (the usual order: the move takes a round trip).
    @Test func theRailShowsAfterAGroupDropsPastAnEmptyGroup() throws {
        let drops = Drops()
        let (list, window) = Self.list(drops)
        defer { window.close() }
        Self.expectRails(list, "at rest")
        try Self.dragInfraPastEmpty(list)
        #expect(drops.targets == [SidebarDocTarget(section: Self.section, after: "g_\(Self.empty.rawValue)")], "drops: \(drops.targets)")
        Self.echo(list)
        if let landing = list.landing { list.finishLand(landing, then: nil) }
        #expect(list.settling == nil && list.landing == nil, "the drop never settled: \(Self.describe(list))")
        Self.expectRails(list, "after the drop")
        // A later reload with nothing new (a theme or config change) keeps them.
        list.reload(animated: false)
        Self.expectRails(list, "after a reload")
    }
}

import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-27 (ask-2663fecb03): "5 different font colors in sidebar (opacity?)".
///
/// Renders a sidebar with every kind of list row that draws on the sidebar's own background (a machine
/// section, a folder group with a member, a loose workspace, an archived one) and counts the distinct
/// text colors its visible labels resolve to. The sidebar's text takes three inks
/// (`SidebarStyle.TextInk`) and no per-label opacity. Each case prints an `INKS|` line with the count
/// and the colors so a fleet log shows the measured number.
@MainActor @Suite(.serialized) struct SidebarTextInkCountTests {
    private static let group = GroupID("grp-ink")
    private static let member = WorkspaceID("ws-ink-member")
    private static let loose = WorkspaceID("ws-ink-loose")
    private static let archived = WorkspaceID("ws-ink-archived")

    private static func sidebar() -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        var old = SidebarWorkspace(id: archived, title: "Old work")
        old.isArchived = true
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .group(SidebarGroup(id: group, name: "cmux-next app", color: .blue, isCollapsed: false,
                                    workspaces: [SidebarWorkspace(id: member, title: "member")])),
                .workspace(SidebarWorkspace(id: loose, title: "Work on cmux")),
                .workspace(old),
            ]),
        ])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach {
            $0.layoutSubtreeIfNeeded()
            $0.updateLayer()
        }
        return sidebar
    }

    /// Every visible label under `view`: its text color, resolved in the view's appearance.
    private static func inks(in view: NSView) -> [String] {
        var found: [String] = []
        func key(_ color: NSColor) -> String {
            var resolved = color
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.sRGB) ?? color
            }
            let parts = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent, resolved.alphaComponent]
            return parts.map { String(format: "%.2f", $0) }.joined(separator: ",")
        }
        func walk(_ node: NSView) {
            guard !node.isHidden else { return }
            if let field = node as? NSTextField, !field.stringValue.isEmpty, let color = field.textColor {
                found.append(key(color))
            } else if let marquee = node as? MarqueeLabel, !marquee.stringValue.isEmpty {
                found.append(key(marquee.textColor))
            }
            node.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    @Test func sidebarTextUsesAtMostThreeInks() throws {
        let sidebar = Self.sidebar()
        let rows = sidebar.list.rowViews.values.filter { $0 is WorkspaceRowView || $0 is GroupHeaderRowView || $0 is SectionHeaderRowView }
        try #require(rows.count >= 4, "expected the section, group and workspace rows, got \(rows.count)")
        let distinct = Set(rows.flatMap { Self.inks(in: $0) })
        print("INKS|count=\(distinct.count)|\(distinct.sorted().joined(separator: " "))")
        #expect(distinct.count <= SidebarStyle.TextInk.allCases.count,
                "sidebar text uses \(distinct.count) inks: \(distinct.sorted())")
    }
}

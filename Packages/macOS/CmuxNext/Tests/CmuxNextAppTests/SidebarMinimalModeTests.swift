import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Minimal mode (`sidebar.minimal`, cx-w1r5): "Workspace rows show only their icon, name and
/// unread mark, and section titles become thin lines." Dogfood nxdog93 (cx-7swgy): with it on, a
/// sidebar of quiet rows and a New Group header looked exactly as with it off. On, the list is
/// visibly compact: every row is shorter, a group's header is a shorter solid bar, a status line goes.
@MainActor
struct SidebarMinimalModeTests {
    private static let reported = ResourceID(rawValue: "ws-reported")
    private static let quiet = ResourceID(rawValue: "ws-quiet")
    private static let group = GroupID("grp-new")

    /// A sidebar under its own settings: a quiet workspace, and a New Group holding one that
    /// reports two status entries (a block: one entry would sit on the name's line).
    private static func sidebar() -> (SidebarView, DesignSettings, quiet: WorkspaceID, reported: WorkspaceID) {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: nil, resourceID: quiet, name: "notes"),
            WorkspaceSnapshot(id: 2, key: nil, resourceID: reported, name: "build"),
        ]))
        var mirror = SessionStateMirror()
        mirror.workspaceStatus[reported] = WorkspaceStatus(
            workspaceID: reported, entries: [WorkspaceStatus.Entry(key: "build", text: "Building", icon: "hammer", color: "#ff8800"),
                                         WorkspaceStatus.Entry(key: "tests", text: "412 passed")])
        store.session.apply(.snapshot(mirror), in: store)
        let mapped = SidebarMapping.shared.sections(store.sidebarSections,
                                                    machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
        let section = mapped[0]
        let workspaces = section.workspaces
        let notes = workspaces.first { $0.title == "notes" }!, build = workspaces.first { $0.title == "build" }!
        let sections = [SidebarSection(kind: section.kind, nodes: [
            .workspace(notes), .group(SidebarGroup(id: Self.group, name: "New Group", workspaces: [build])),
        ])]
        let design = DesignSettings()
        // The status block is opt-in since Lawrence 2026-10-21: on here, so minimal mode has one to drop.
        design.sidebarSections.workspaceRow.base.shown.insert(.agentStatus)
        let sidebar = SidebarView(model: SidebarModel(sections: sections), design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        return (sidebar, design, notes.id, build.id)
    }

    private struct Heights: Equatable {
        var quiet: CGFloat, header: CGFloat, reported: CGFloat
    }

    /// The rows' heights once the sidebar shows `minimal` (its settings arrive on an observation,
    /// a run-loop turn later).
    private static func heights(_ sidebar: SidebarView, _ ids: (quiet: WorkspaceID, reported: WorkspaceID),
                                until check: (Heights) -> Bool) async -> Heights? {
        func read() -> Heights? {
            let layout = sidebar.list.displayed
            guard let quiet = layout.row(for: .workspace(ids.quiet)), let header = layout.row(for: .group(Self.group)),
                  let reported = layout.row(for: .workspace(ids.reported)) else { return nil }
            return Heights(quiet: quiet.height, header: header.height, reported: reported.height)
        }
        for _ in 0..<100 {
            if let heights = read(), check(heights) { return heights }
            try? await Task.sleep(for: .milliseconds(10))
            sidebar.layoutSubtreeIfNeeded()
        }
        return read()
    }

    @Test func minimalModeMakesTheListVisiblyCompact() async throws {
        let (sidebar, design, quiet, reported) = Self.sidebar()
        let ids = (quiet: quiet, reported: reported)
        let line = SidebarLayoutMetrics.standard.rowHeight
        // Off: the status entry draws under build's name.
        let off = try #require(await Self.heights(sidebar, ids) { $0.reported > line })
        design.sidebarSections.minimal = true
        let on = try #require(await Self.heights(sidebar, ids) { $0.reported <= line })
        // Shorter rows, a shorter group header, and no status line.
        #expect(on.quiet < off.quiet)
        #expect(on.header < off.header)
        #expect(on.reported == on.quiet)
        #expect(sidebar.list.displayed.row(for: .workspace(reported))?.content?.status == nil)
        // The shorter header keeps its solid bar (Lawrence 2026-10-18): the editor opens from it.
        sidebar.layoutSubtreeIfNeeded()
        let header = try #require(sidebar.list.rowViews[.group(Self.group)] as? GroupHeaderRowView)
        header.layoutSubtreeIfNeeded()
        #expect(header.labelFrame.width == header.bounds.width)
        #expect(header.labelFrame.height > Metrics.dividerThickness * 4)
        #expect(header.labelFrame.minX <= header.titleFrame.minX)
        // Off again: the list is as it was.
        design.sidebarSections.minimal = false
        #expect(await Self.heights(sidebar, ids) { $0 == off } == off)
    }
}

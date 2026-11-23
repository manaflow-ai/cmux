import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Lucas 2026-11-12: workspaces nobody named ("workspace-1", "workspace-2", a shell at "~") read in the same
/// white as every other row in the left sidebar. #22840 drew them in the secondary ink while idle; this
/// takes that back. The rows come from a daemon store through the sidebar mapping, as the app builds them.
@MainActor @Suite(.serialized) struct SidebarUnnamedRowInkTests {
    private static let mac = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    /// Workspaces with these names, each with one idle shell in `cwd`.
    private static func store(_ names: [String], cwd: String) -> DaemonStore {
        let store = DaemonStore()
        let workspaces = names.enumerated().map { index, name in
            let id = UInt64(index + 1)
            let tab = TabSnapshot(surface: SurfaceID(rawValue: id), name: nil, title: "", cwd: cwd)
            let pane = PaneSnapshot(id: PaneID(rawValue: id), focusedAt: 1, tabs: [tab])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(PaneID(rawValue: id)), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: nil, name: name, screens: [screen])
        }
        store.apply(snapshot: DaemonTree(workspaces: workspaces))
        return store
    }

    /// The front tab's label as the auto name gives it: an idle shell's folder, only while nobody named the workspace.
    private static func folderLabel(_ workspace: WorkspaceModel, _ tab: TabModel, _: TabModel?) -> SidebarMapping.PageFace? {
        .init(title: workspace.isUnnamed ? tab.cwd.map { $0 == NSHomeDirectory() ? "~" : String($0.split(separator: "/").last ?? "") } : nil,
              favicon: nil)
    }

    /// No label from the front tab: the row shows the workspace's own name ("workspace-1").
    private static func noLabel(_: WorkspaceModel, _: TabModel, _: TabModel?) -> SidebarMapping.PageFace? { nil }

    private static func sidebar(_ store: DaemonStore,
                                pageFace: @escaping (WorkspaceModel, TabModel, TabModel?) -> SidebarMapping.PageFace?) -> SidebarView {
        let sections = SidebarMapping.shared.sections(store.sidebarSections, machine: mac, pageFace: pageFace, terminalTitle: "Terminal")
        let sidebar = SidebarView(model: SidebarModel(sections: sections), design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded(); $0.updateLayer() }
        return sidebar
    }

    /// Each workspace row's title with its ink and the sidebar's title ink, read under the row's theme.
    private static func inks(_ sidebar: SidebarView) -> [(title: String, ink: NSColor?, want: NSColor)] {
        sidebar.list.rowViews.values.compactMap { $0 as? WorkspaceRowView }.map { row in
            var ink: NSColor?, want = NSColor.clear
            row.performWithTheme { ink = row.title.textColor; want = Palette.sidebarTitle }
            return (row.title.stringValue, ink, want)
        }
    }

    @Test func anIdleUnnamedRowReadsInTheSameInkAsANamedRow() throws {
        let sidebar = Self.sidebar(Self.store(["workspace-1", "workspace-2", "api"], cwd: "/tmp/cmux-unnamed-ink"), pageFace: Self.noLabel)
        let rows = Self.inks(sidebar)
        #expect(Set(rows.map(\.title)) == ["workspace-1", "workspace-2", "api"], "the rows show the daemon's default names")
        for row in rows {
            #expect(row.ink == row.want, "\(row.title) reads in the sidebar title's ink")
        }
    }

    @Test func aShellAtHomeReadsInTheSameInkAsANamedRow() throws {
        let sidebar = Self.sidebar(Self.store(["workspace-3"], cwd: NSHomeDirectory()), pageFace: Self.folderLabel)
        let rows = Self.inks(sidebar)
        #expect(rows.map(\.title) == ["~"], "the row shows its home folder")
        for row in rows {
            #expect(row.ink == row.want, "\(row.title) reads in the sidebar title's ink")
        }
    }
}

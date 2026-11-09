import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/37374: opening a workspace from Home showed no right dock in the
/// right sidebar's Dock section, while opening the same workspace from another workspace did. The section read
/// the shown workspace once, when the panel opened, so what it listed depended on where the person came from.
///
/// A real window with three workspaces: `k0` plays Home (a pinned chat dock on the left, as Home's Chief), `k1` has
/// a column docked on the right, and `k2` has none. With the Dock section open, `k1` must list its right dock
/// however it is reached: from Home, from a workspace with no dock, and back from a page.
@MainActor @Suite(.serialized, .closesItsWindows)
struct RightSidebarDockFollowsTests {
    typealias Fixture = SidebarMultiViewWindowTests.Fixture
    static let keys = ["k0", "k1", "k2"]

    static func tree() -> DaemonTree {
        func screen(_ index: Int) -> ScreenSnapshot {
            let base = UInt64(10 * (index + 1))
            let first = PaneSnapshot(id: PaneID(rawValue: base), tabs: [TabSnapshot(surface: SurfaceID(rawValue: base), title: "main \(index)")])
            guard index < 2 else { return ScreenSnapshot(id: ScreenID(rawValue: base), layout: .leaf(first.id), panes: [first]) }
            let second = PaneSnapshot(id: PaneID(rawValue: base + 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: base + 1), title: index == 0 ? "Chief" : "notes")])
            // `k0` (Home): the Chief in a pinned chat dock on the left. `k1`: a column docked on the right.
            let dock = index == 0 ? DockSnapshot(edge: .left, mode: .docked, role: .agentChat, isPinned: true) : DockSnapshot(edge: .right, mode: .docked)
            let columns = index == 0
                ? [ColumnSnapshot(id: ColumnID(rawValue: base + 2), width: 0.3, layout: .leaf(second.id), dock: dock), ColumnSnapshot(id: ColumnID(rawValue: base + 3), width: 0.7, layout: .leaf(first.id))]
                : [ColumnSnapshot(id: ColumnID(rawValue: base + 2), width: 0.7, layout: .leaf(first.id)), ColumnSnapshot(id: ColumnID(rawValue: base + 3), width: 0.3, layout: .leaf(second.id), dock: dock)]
            return ScreenSnapshot(id: ScreenID(rawValue: base), layout: .leaf(first.id), columns: columns, panes: [first, second])
        }
        var tree = DaemonTree(registryID: "s-local", workspaces: keys.enumerated().map { index, key in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key, screens: [screen(index)])
        })
        tree.personal = PersonalState(workspaces: keys.enumerated().map { index, key in
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: key), index: index)
        })
        return tree
    }

    /// What the open Dock section lists: each row's edge and title.
    static func listed(_ f: Fixture) throws -> [String] {
        let section = try #require(f.controller.root.rightPanel?.shownSection as? DockSectionHostView)
        return section.model.rows.map { "\($0.edge.rawValue):\($0.title)" }
    }

    func show(_ id: String, in f: Fixture) {
        f.services.windows.show(workspaceID: id, in: f.state, from: .thisWindow)
        #expect(f.controller.content?.workspace.id == id, "\(id) is not the shown workspace")
    }

    @Test func theDockSectionListsTheShownWorkspacesDockWhereverItWasOpenedFrom() async throws {
        // The fixture's window remembers the right sidebar in `.standard`: put both keys back as found, so no later
        // window in this process opens with the Dock section (and a narrower content area).
        let defaults = UserDefaults.standard, keys = [RightSidebarModel.visibleKey, RightSidebarModel.modeKey]
        let before = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, before) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        let f = try await Fixture(keys: Self.keys, tree: Self.tree())
        defer { f.close() }
        show("k0", in: f)
        // The path every Dock switch takes (palette, menu, `switchRightSidebarToDock`), on this window.
        #expect(f.controller.showRightSidebar(.dock))
        #expect(try Self.listed(f) == ["left:Chief"], "Home lists its Chief dock")

        // From Home: the workspace's right dock, not Home's left one (the reported case).
        show("k1", in: f)
        #expect(try Self.listed(f) == ["right:notes"], "opened from Home, k1 listed another workspace's docks")

        // From a workspace with no dock, the same workspace lists the same dock.
        show("k2", in: f)
        #expect(try Self.listed(f).isEmpty, "k2 has no docked column")
        show("k1", in: f)
        #expect(try Self.listed(f) == ["right:notes"], "opened from k2, k1 listed another workspace's docks")

        // A page over the content area: no workspace is shown, so no dock is listed; leaving it lists k1's again.
        f.controller.parkContentForPage()
        #expect(try Self.listed(f).isEmpty, "a page lists the docks of the workspace under it")
        f.controller.showWorkspace(requested: "k1")
        #expect(try Self.listed(f) == ["right:notes"], "back from a page, k1 lost its right dock")
    }
}

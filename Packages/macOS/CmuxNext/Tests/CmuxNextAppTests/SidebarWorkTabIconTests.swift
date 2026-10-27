import CmuxNextBridge
import CmuxNextBridgeUI
import CmuxNextDaemon
import CmuxNextSidebar
import CoreGraphics
import Testing

/// The row's icon follows its name (Leo 2026-10-21: "why did this turn into the githb favicon?"):
/// a page focused in a split beside a chat or terminal leaves the row's icon to that work, as its
/// name already does, while a workspace of pages alone still shows its front page's favicon.
@MainActor
struct SidebarWorkTabIconTests {
    private static let favicon: SidebarFavicon = {
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return SidebarFavicon(context.makeImage()!)
    }()

    private static func row(_ panes: [PaneSnapshot]) throws -> SidebarWorkspace {
        let store = DaemonStore()
        let layout: LayoutNode = panes.count == 1 ? .leaf(1)
            : .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(1), b: .leaf(2))
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "workspace-3",
                                                                        screens: [ScreenSnapshot(id: 1, layout: layout, panes: panes)])]))
        let workspace = try #require(store.workspaces.first)
        return SidebarMapping.shared.row(workspace, machine: .local, pageFace: { _, tab, _ in
            tab.kind == .browser ? .init(title: "Pull request", favicon: favicon) : nil
        })
    }

    private static let page = TabSnapshot(surface: 2, kind: .browser, title: "PR", url: "https://github.com")

    @Test func aPageBesideWorkLeavesTheRowIconToTheWork() throws {
        let row = try Self.row([
            PaneSnapshot(id: 1, focusedAt: 1, tabs: [TabSnapshot(surface: 1, kind: .pty, title: "coordinator")]),
            PaneSnapshot(id: 2, focusedAt: 2, tabs: [Self.page]),
        ])
        #expect(row.icon == nil)
        // The page keeps its favicon in the row's tab list.
        #expect(row.tabs.first(where: { $0.kind == .browser })?.favicon == Self.favicon)
    }

    @Test func aWorkspaceOfPagesShowsItsPagesFavicon() throws {
        let row = try Self.row([PaneSnapshot(id: 1, focusedAt: 1, tabs: [Self.page])])
        #expect(row.icon == .favicon(Self.favicon))
    }
}

import CoreGraphics
@testable import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Testing

/// A chat that opens a link (an agent's PR in the column on its right) keeps its own name and kind in
/// the sidebar. The row's icon follows the tab focused last (15fa0f98, Lawrence msg 23802: "workspace
/// favicon needs to reflect the latest focused/interacted entity"): none while the chat has focus
/// (Leo, 2026-10-21: "GUI push · coordinator" showed GitHub's mark after #23105), the page's favicon
/// while the page has it.
@MainActor
struct SidebarRowPageBesideChatTests {
    private static let github: SidebarFavicon = {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return SidebarFavicon(context.makeImage()!)
    }()

    /// Each tab's face as `AppServices.sidebarPageFace` gives it: the name of the work a page
    /// yields to (else the tab's own), and a favicon for a browser tab only.
    private static func pageFace(_: WorkspaceModel, _ tab: TabModel, _ work: TabModel?) -> SidebarMapping.PageFace? {
        .init(title: (work ?? tab).title, favicon: tab.kind == .browser ? github : nil)
    }

    /// A GitHub page in its own pane, focused at 2, and with `chat` an agent chat on its left
    /// focused at `chatFocusedAt`.
    private static func workspace(chat: Bool, chatFocusedAt: UInt64 = 1) throws -> (WorkspaceModel, TabModel?) {
        let store = DaemonStore()
        let page = PaneSnapshot(id: 2, focusedAt: 2, tabs: [
            TabSnapshot(surface: 2, kind: .browser, title: "PR", url: "https://github.com/manaflow-ai/cmux/pull/23025"),
        ])
        var panes = [page]
        var layout = LayoutNode.leaf(2)
        if chat {
            var tab = TabSnapshot(surface: 1, kind: .conversation, title: "GUI push · coordinator")
            tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:test", session: "s1", harness: "claude"))
            panes.insert(PaneSnapshot(id: 1, focusedAt: chatFocusedAt, tabs: [tab]), at: 0)
            layout = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(1), b: .leaf(2))
        }
        let screen = ScreenSnapshot(id: 1, layout: layout, panes: panes)
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "workspace-3", screens: [screen])]))
        let workspace = try #require(store.workspaces.first)
        return (workspace, workspace.screens.flatMap(\.panes).flatMap(\.tabs).first { $0.kind == .conversation })
    }

    /// The row's title and kind are the chat's whichever pane has focus: the chat, or the page it
    /// opened on its right after focus moved there. Its icon is the focused page's favicon, none
    /// while the chat has focus.
    @Test(arguments: [UInt64(3), 1])
    func theRowShowsTheChatWhereverFocusIs(chatFocusedAt: UInt64) throws {
        let (workspace, chat) = try Self.workspace(chat: true, chatFocusedAt: chatFocusedAt)
        let chatTab = try #require(chat)
        let picks = SidebarMapping.shared.faceTabs(workspace, selectedTab: { _ in nil })
        #expect(picks.front?.kind == (chatFocusedAt > 2 ? .conversation : .browser))
        #expect(picks.face?.id == chatTab.id)
        let row = SidebarMapping.shared.row(workspace, machine: .local, pageFace: Self.pageFace)
        #expect(row.title == "GUI push · coordinator")
        #expect(row.icon == (chatFocusedAt > 2 ? nil : .favicon(Self.github)), "the row's icon is the focused tab's")
        #expect(row.kind == .harness)
        #expect(row.kindBrand != nil && row.kindBrand == chatTab.agentBrand)
        // The page's own tab keeps its favicon.
        #expect(row.tabs.first { $0.kind != .agentChat }?.favicon == Self.github)
    }

    /// A workspace of pages alone still shows its front page's favicon (cx-e32b).
    @Test func aPageWithNoWorkBesideItKeepsItsFavicon() throws {
        let (workspace, _) = try Self.workspace(chat: false)
        let row = SidebarMapping.shared.row(workspace, machine: .local, pageFace: Self.pageFace)
        #expect(row.title == "PR")
        #expect(row.icon == .favicon(Self.github))
        #expect(row.kind == .browser)
    }
}

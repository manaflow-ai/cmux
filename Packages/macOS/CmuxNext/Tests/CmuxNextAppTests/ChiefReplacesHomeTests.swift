import AppKit
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import CmuxNextDesign
@testable import CmuxNextApp
@testable import CmuxNextHome
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The person, 2026-11-20 (msg 44729): "we need to redesign chief so we replace home with chief". David Beyer,
/// Nov 20: the Chief is a thread like the others ("threads should all be threads"), distinct in the sidebar.
///
/// The sidebar's top row that was Home is the Chief: its name, its picture, its status and its subagents under it.
/// Opening it shows the Chief's chat with the conversation list beside it, as in Messages (#48467); there is no
/// Chats button to fold it.
@MainActor @Suite(.serialized, .closesItsWindows)
struct ChiefReplacesHomeTests {
    static let homeItem = LayoutItem(id: LayoutItemID("itm_home"), ref: SidebarLayoutDocument.homeRef)
    static let storeItem = LayoutItem(id: LayoutItemID("itm_app_store"), ref: .app("cmux/app-store"))

    static func layout(_ items: [LayoutItem]) -> SidebarLayoutDocument {
        SidebarLayoutDocument(sections: [LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, items: items)])
    }

    static func picture() throws -> SidebarFavicon {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.4, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return SidebarFavicon(try #require(context.makeImage()))
    }

    /// The top row reads as the Chief: its name and picture, its status and the subagents that need the person,
    /// and the blue dot while another chat is unread.
    @Test func theTopRowIsTheChiefThread() throws {
        let shown = ChiefSidebar.shared.status
        defer { ChiefSidebar.shared.status = shown }
        ChiefSidebar.shared.status = ChiefSidebar.Status(activity: .waiting, badge: 2)
        let picture = try Self.picture()
        let infos = SidebarBridge.itemInfo(for: SidebarLayoutDocument.defaults, registered: { _ in true }, homeUnread: 1,
                                           chiefFavicon: picture)
        let row = try #require(infos[Self.homeItem.id], "the default layout has no top row for the Chief")
        #expect(row.title == SidebarBuiltIn.home.title && row.title != SidebarBuiltIn.chief.title,
                "the top row is named \(row.title), not Chief (Chief Activity is the other item, cmux#48416)")
        #expect(row.favicon == picture, "the top row does not show the Chief's picture")
        #expect(row.activity == .waiting, "the top row does not show that the Chief needs the person (\(row.activity))")
        #expect(row.badge == 2, "the top row does not count the subagents that need the person (\(String(describing: row.badge)))")
        #expect(row.unreadDot, "another unread chat no longer shows on the top row")
    }

    /// The Chief's subagents draw as indented rows right under the Chief's top row, before the next item.
    @Test func theChiefsSubagentsDrawUnderTheTopRow() {
        let lanes = [ChiefSidebarItemTests.lane("optchat-sub-6b68ac4a-a2", .working, title: "Fix the build")]
        let rows = SidebarTransientItem.chiefSubagents(lanes: lanes, showsIdle: false)
        let model = SidebarModel()
        model.transientTopItems = rows
        let placed = model.placingTransientItems(in: Self.layout([Self.homeItem, Self.storeItem]).sections).flatMap(\.items).map(\.id.rawValue)
        #expect(placed == ["itm_home"] + rows.map(\.item.id.rawValue) + ["itm_app_store"], "placed: \(placed)")
    }

    /// The Chief's chat opens with the conversation list beside it at its width, as before the Chats button
    /// (#48467: the user asked for Messages' two columns back), in light and dark.
    @Test(arguments: [false, true])
    func theChiefChatHasTheListBesideIt(dark: Bool) throws {
        _ = NSApplication.shared
        let suite = "cmux.tests.chiefReplacesHome.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let list = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        list.update(HomeLoneChiefRailTests.model(chiefs: 3))
        let split = HomeSidebarSplitView(sidebar: list, content: NSView(), widths: HomeSidebarWidth(defaults: defaults))
        split.windowKey = { "chief" }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.close() }
        window.contentView = split
        split.layoutSubtreeIfNeeded()
        #expect(split.showsList)
        #expect(abs(split.sidebarWidth - HomeSidebarWidth.standard) < 1, "the list beside the Chief is \(split.sidebarWidth) pt")
    }

    /// The chat's top-left has compose alone, where Messages draws it: no Chats button, and a list folded with
    /// the old button (its old key) shows again.
    @Test func composeAloneAtTheChatTopLeft() throws {
        _ = NSApplication.shared
        let suite = "cmux.tests.chiefReplacesHome.compose.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "cmux.home.chatListShown")
        let list = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        list.update(HomeLoneChiefRailTests.model(chiefs: 3))
        let split = HomeSidebarSplitView(sidebar: list, content: NSView(), widths: HomeSidebarWidth(defaults: defaults))
        split.windowKey = { "compose" }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = split
        split.chatColumn.showsCompose = true
        split.layoutSubtreeIfNeeded()
        #expect(split.showsList, "a list folded with the old Chats button stayed folded")
        #expect(split.chatColumn.chats.isHidden, "the Chats button still shows")
        #expect(split.chatColumn.compose.frame.minX == HomeChatColumnView.composeInset, "compose left its top-left inset")
    }

    /// A click on the top row (the Home item, app or built-in) opens the Chief's chat, as the Chief item does, and
    /// its menu has the subagent fold.
    @Test func theTopRowOpensTheChief() {
        #expect(ChiefSidebar.opensChief(SidebarLayoutDocument.homeRef))
        #expect(ChiefSidebar.opensChief(.builtIn(.home)))
        #expect(!ChiefSidebar.opensChief(.app("cmux/app-store")))
        #expect(SidebarBridge.builtInActions[.chief] == ChiefSidebar.openAction)
        #expect(SidebarTransientItem.chiefAnchors.contains(SidebarLayoutDocument.homeRef))
    }
}

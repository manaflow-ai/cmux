import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// With Settings > Show Chats on, the real Chats section (an app section
/// after the workspaces, drawn by `SidebarChatsView`) shrinks and scrolls in
/// the band below the list; the footer (the profile control) stays in the
/// window at every window height down to the window's minimum (320 pt).
@MainActor @Suite(.serialized) struct SidebarChatsFooterTests {
    static let account = LayoutItemID("itm_account")

    /// Gives the sidebar the App's Chats section with `count` chats.
    final class ChatsProvider: SidebarAppSectionProvider {
        let view = SidebarChatsView(defaults: UserDefaults(suiteName: "SidebarChatsFooterTests") ?? .standard)
        var onContentChange: (() -> Void)?
        init(count: Int) {
            view.update((0..<count).map { SidebarChatsView.Row(id: "claude:s\($0)", title: "Chat \($0)", harness: "claude", brand: nil) },
                        enabled: true, ready: true)
        }
        func title(for contribution: String) -> String? { SidebarChatsView.title }
        func makeView(for contribution: String) -> NSView? { contribution == SidebarChatsView.contribution ? view : nil }
        func preferredHeight(for contribution: String, width: CGFloat) -> CGFloat {
            contribution == SidebarChatsView.contribution ? view.preferredHeight : 0
        }
    }

    private func sidebar(height: CGFloat, provider: ChatsProvider) -> SidebarView {
        let model = SidebarModel()
        model.profiles = [SidebarProfile(id: ProfileKey("default"), name: "Default"), SidebarProfile(id: ProfileKey("p2"), name: "Two")]
        model.activeProfileID = ProfileKey("default")
        var info = SidebarBuiltIn.account.defaultInfo
        info.avatar = SidebarAvatar(name: "Work", color: nil)
        info.title = "Work"
        model.itemInfo = [Self.account: info]
        model.layout = SidebarLayoutDocument.defaults.chatsLayout(enabled: true)
        let view = SidebarView(model: model)
        view.appSections = provider
        view.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        view.layoutSubtreeIfNeeded()
        view.layout()
        return view
    }

    /// The profile control is inside the sidebar, unclipped and uncovered by
    /// the Chats section, which ends above it and scrolls.
    @Test(arguments: [CGFloat(320), 400, 520, 800])
    func theFooterStaysVisibleWithChatsOn(height: CGFloat) throws {
        let provider = ChatsProvider(count: 40)
        let view = sidebar(height: height, provider: provider)
        let account = try #require(view.footerRegion.itemView(Self.account), "the profile control is in the pinned footer")
        #expect(!account.isHiddenOrHasHiddenAncestor)
        let frame = account.convert(account.bounds, to: view)
        #expect(frame.height > 0 && view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(frame) in \(view.bounds)")
        if let scroll = account.enclosingScrollView {
            let visible = scroll.contentView.convert(scroll.contentView.bounds, to: view)
            #expect(visible.insetBy(dx: -0.5, dy: -0.5).contains(frame), "clipped: \(frame) in \(visible)")
        }
        // The Chats section is in the band below the list, which ends above the footer.
        #expect(provider.view.superview === view.belowRegion, "Chats draws in the band below the list")
        let band = view.belowScroll.convert(view.belowScroll.bounds, to: view)
        #expect(band.maxY <= frame.minY + 0.5, "the Chats band ends above the footer: \(band) \(frame)")
        // Whatever of the Chats view shows is inside the band, never over the footer.
        let chats = provider.view.convert(provider.view.bounds, to: view).intersection(band)
        #expect(chats.isNull || chats.maxY <= frame.minY + 0.5, "\(chats) \(frame)")
        // No sibling above the footer (a card, the list, a band) takes the control's clicks.
        let index = try #require(view.subviews.firstIndex { $0 === view.footerRegion })
        let center = NSPoint(x: frame.midX, y: frame.midY)
        for cover in view.subviews[(index + 1)...] {
            #expect(cover.hitTest(center) == nil, "\(cover) covers the profile control: \(cover.frame) \(frame)")
        }
    }

    /// In a small window the Chats section shrinks below its full height and
    /// scrolls inside; in a tall window it shows in full.
    @Test func chatsShrinkInASmallWindowFirst() throws {
        let small = sidebar(height: 320, provider: ChatsProvider(count: 40))
        #expect(small.belowRegion.frame.height > small.belowScroll.contentView.bounds.height + 0.5, "the Chats band scrolls")
        let tall = sidebar(height: 1200, provider: ChatsProvider(count: 40))
        #expect(abs(tall.belowRegion.frame.height - tall.belowScroll.contentView.bounds.height) <= 0.5, "full height in a tall window")
    }
}

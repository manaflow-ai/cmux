import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// MessagesLab 69f4256's context menu in the Home pane: the real order
/// (tapback rows, Tapback Details…, Attach Sticker…, Copy, Share…), with no
/// entry HomeStore cannot honour (Reply…: no reply op; Delete…: no local
/// hide; Edit and Undo Send: no edit or unsend op).
@MainActor @Suite struct PaneMenuTests {
    private func menu(online: Bool = true, reactions: [CmuxHomeCore.Reaction] = []) -> (NSMenu?, ChatController) {
        let (p, c) = Fixture2.projection()
        p.isSendEnabled = online
        var items = Fixture2.history(6)
        if let i = items.lastIndex(where: { $0.author == Fixture2.them }) { items[i].reactions = reactions }
        p.apply(items: items, summary: Fixture2.summary(lastSeq: 6), typing: [], hasOlder: false)
        c.host.layoutSubtreeIfNeeded()
        c.demo.layoutIfNeeded()
        c.demo.collection.layoutIfNeeded()
        guard let hit = c.demo.lastTextRow(mine: false) else { return (nil, c) }
        return (c.menu(at: CGPoint(x: hit.body.midX, y: hit.body.midY)), c)
    }

    private func titles(_ m: NSMenu?) -> [String] { (m?.items ?? []).filter { !$0.isSeparatorItem && $0.submenu == nil }.map(\.title) }

    @Test func offersTheRealMenuWithoutEntriesHomeCannotHonour() throws {
        let (m, _) = menu()
        let menu = try #require(m)
        #expect(menu.items.prefix(2).allSatisfy { $0.submenu?.presentationStyle == .palette }, "two tapback palette rows first")
        #expect(titles(menu) == [Strings.menuTapbackDetails, Strings.menuAttachSticker, Strings.menuCopy, Strings.menuShare])
        #expect(!titles(menu).contains(Strings.menuReplyEllipsis))
        #expect(!titles(menu).contains(Strings.menuDelete))
        #expect(menu.items.last?.isSeparatorItem == false)
        #expect(menu.delegate is MenuHighlight, "the target bubble is highlighted while the menu is open")
    }

    @Test func offlineDropsTapbackEntries() throws {
        let (m, _) = menu(online: false)
        let menu = try #require(m)
        #expect(menu.items.allSatisfy { $0.submenu == nil })
        #expect(titles(menu) == [Strings.menuTapbackDetails, Strings.menuCopy, Strings.menuShare])
    }

    @Test func tapbackDetailsListsWhoReactedFromHomeStore() throws {
        let (_, c) = menu(reactions: [CmuxHomeCore.Reaction(author: Fixture2.me, partIndex: 0, kind: .tapback(.love))])
        let hit = try #require(c.demo.lastTextRow(mine: false))
        #expect(hit.row.reactions.map(\.senderId) == [Fixture2.me.rawValue])
        #expect(c.store.state.conversation.participants.first { $0.id == Fixture2.me.rawValue }?.displayName != nil)
    }
}

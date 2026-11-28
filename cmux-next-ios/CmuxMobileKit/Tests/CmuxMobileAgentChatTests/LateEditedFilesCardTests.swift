import Foundation
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// The edited-files card (`f-<turn>`) goes in only once its turn has ended and its diff is
/// computed off the main thread (`ChatTranscriptBuilder`, `ChatDiffCache`): a later reload than
/// the rows under it. That reload's own pass holds the newest row where the reader sees it, for a
/// reader on the newest turn too; the dock's pin to the bottom comes only after the collection
/// view lays out again, and the card's frame drew the rows under it pushed down 175 to 326 pt
/// (#59189, PlaceholderBoundUITests under heavy duress, every chat flow).
@MainActor
@Suite struct LateEditedFilesCardTests {
    @Test(arguments: [true, false])
    func aLateEditedFilesCardMovesNoRowUnderItInAnyPass(following: Bool) async {
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        store.nextFrame = nil
        store.apply(.batch((0..<12).flatMap { SmoothChatTests.turn($0, edit: $0 == 11) }))
        let surface = AgentChatSurface()
        surface.following = following
        let list = ChatTranscriptList(store: store, surface: surface)
        let scroll = list.collectionView
        scroll.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        list.boundsMayHaveChanged()
        scroll.layoutIfNeeded()
        // The reader on the newest turn's last rows.
        scroll.contentOffset.y = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height)
        scroll.layoutIfNeeded()
        guard !list.layout.items.contains(where: { $0.id == "f-t11" }), let newest = list.layout.items.last?.id,
              let start = list.layout.top(of: newest) else {
            Issue.record("the card was in before its diff settled, or no rows: \(list.layout.items.map(\.id))")
            return
        }
        let seen = start - scroll.contentOffset.y
        var passes: [String] = []
        func check(_ pass: String) {
            let now = (list.layout.top(of: newest) ?? .greatestFiniteMagnitude) - scroll.contentOffset.y
            if abs(now - seen) > 0.5 { passes.append("\(pass): \(newest) \(seen)->\(now)") }
        }
        await store.diffs.settle()
        list.reload()
        #expect(list.layout.items.contains { $0.id == "f-t11" }, "the card did not go in once its diff settled")
        check("the card's reload")
        scroll.layoutIfNeeded()
        check("the layout pass after it")
        // The card's native layout lands off the main thread and reloads again: each pass after.
        for pass in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
            check("turn \(pass) before layout")
            scroll.layoutIfNeeded()
            check("turn \(pass) after layout")
        }
        #expect(passes.isEmpty, "the rows under the card moved: \(passes.joined(separator: "; "))")
    }

    /// The card goes in at its estimate and its cell then measures taller (a diff card's file rows
    /// wrap): the collection view's self-sizing pass, not `reload`. For a reader on the newest turn
    /// that pass left the rows under the card pushed down until the dock's pin a layout later
    /// (+282 and +332 pt, slow-history-chat and tab-grid-51 under heavy duress, #59189). The
    /// measuring pass itself has to move the list by the card's growth, for a following reader too.
    @Test(arguments: [true, false])
    func aLateCardMeasuringTallerThanItsEstimateMovesNoRowUnderIt(following: Bool) async {
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        store.nextFrame = nil
        store.apply(.batch((0..<12).flatMap { SmoothChatTests.turn($0, edit: $0 == 11) }))
        let surface = AgentChatSurface()
        surface.following = following
        let list = ChatTranscriptList(store: store, surface: surface)
        let scroll = list.collectionView
        scroll.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        list.boundsMayHaveChanged()
        scroll.layoutIfNeeded()
        await store.diffs.settle()
        list.reload()
        scroll.layoutIfNeeded()
        scroll.contentOffset.y = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height)
        scroll.layoutIfNeeded()
        let layout = list.layout
        guard let row = layout.items.firstIndex(where: { $0.id == "f-t11" }), row + 1 < layout.items.count,
              let newest = layout.items.last?.id, let start = layout.top(of: newest),
              let cardTop = layout.top(of: "f-t11"), let estimate = layout.height(of: "f-t11") else {
            Issue.record("no card with a row under it: \(layout.items.map(\.id))")
            return
        }
        let visibleBottom = scroll.contentOffset.y + scroll.bounds.height - scroll.adjustedContentInset.bottom
        #expect(cardTop + estimate < visibleBottom, "the card is not on screen above the newest row")
        let seen = start - scroll.contentOffset.y
        let growth: CGFloat = 200
        let original = layout.layoutAttributesForItem(at: IndexPath(item: row, section: 0))!
        let preferred = original.copy() as! UICollectionViewLayoutAttributes
        preferred.size.height = estimate + growth
        let context = layout.invalidationContext(forPreferredLayoutAttributes: preferred, withOriginalAttributes: original)
        let now = (layout.top(of: newest) ?? .greatestFiniteMagnitude) - (scroll.contentOffset.y + context.contentOffsetAdjustment.y)
        #expect(abs(now - seen) <= 0.5,
                "the card's measuring pass moved \(newest) \(seen)->\(now) (list moved \(context.contentOffsetAdjustment.y), card grew \(growth))")
    }
}

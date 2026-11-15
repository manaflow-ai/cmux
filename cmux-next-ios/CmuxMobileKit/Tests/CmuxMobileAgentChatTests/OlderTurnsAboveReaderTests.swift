#if os(iOS)
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// Older turns that land above a reader who scrolled up (turns a memory warning put on disk
/// coming back, or the Mac's page before the oldest shown) leave the reader where they are.
///
/// The list keeps the rows the reader sees in place by moving the offset down by the height
/// put in above. Before, the transcript controller then measured the distance from the bottom
/// against the content height of its last layout pass, the one before the insert: the moved
/// offset read as "at the bottom", following came back on, and the next pass pinned the chat
/// to its newest row. The kit's DisclosureAnimationTests went red this way when another suite's
/// memory warning spilled its chat (feat-cmux-next 88d4f432, cmux-next-ios kit job).
///
/// The real transcript controller in a window, as DisclosureAnimationTests drives it.
@MainActor
@Suite(.serialized) struct OlderTurnsAboveReaderTests {
    @Test func spilledTurnsComingBackAboveAReaderScrolledUpKeepThemInPlace() async throws {
        let chat = try await DisclosureAnimationTests().chat()
        defer { chat.window.isHidden = true }
        let store = chat.list.store
        let turns = store.turns.count

        // A memory warning while the reader is at the newest turn: the older turns go to disk.
        chat.list.relieveMemoryPressure()
        await chat.frames(20)
        try #require(store.turnsOnDisk > 0, "the memory warning spilled no turn")
        try #require(chat.surface.following)

        // The reader scrolls up, within read-ahead of the oldest turn shown: the spilled turns
        // come back above what they read.
        chat.surface.following = false
        chat.scroll.contentOffset.y -= chat.scroll.bounds.height * 2.5
        let reading = try #require(chat.onScreen().first, "a row on screen")
        let readingTop = try #require(chat.span(reading)).top
        for _ in 0 ..< 300 where store.turnsOnDisk > 0 || store.turns.count < turns { await chat.frame() }
        try #require(store.turns.count == turns, "the spilled turns came back: \(store.turns.count) of \(turns)")
        await chat.frames(20)

        let bottom = chat.scroll.contentSize.height + chat.scroll.adjustedContentInset.bottom - chat.scroll.bounds.height
        #expect(!chat.surface.following, "following came back on while the reader was scrolled up")
        #expect(bottom - chat.scroll.contentOffset.y > chat.scroll.bounds.height,
                "the chat moved to its newest turn: offset \(chat.scroll.contentOffset.y), bottom \(bottom)")
        let span = try #require(chat.span(reading), "the row the reader was on left the screen")
        #expect(abs(span.top - readingTop) <= 1, "the row the reader was on moved from \(readingTop) to \(span.top)")
    }
}
#endif

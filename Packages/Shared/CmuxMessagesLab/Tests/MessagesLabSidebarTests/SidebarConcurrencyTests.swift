import AppKit
import CoreText
import os
import Testing
@testable import MessagesLabSidebar

/// SWIFT 6 (p10-stability-039): the list draws its rows on every core (`concurrentPerform`, the
/// search and render queues). Its render threads share only values; the text cache's measurement
/// (a CTLine and a CTTypesetter, Core Text layout objects that one thread at a time may use) is
/// lent to one thread at a time; a host's search request answers at most once.
@MainActor
@Suite(.serialized)
struct SidebarConcurrencyTests {
    private static let summary = ConversationSummary(
        id: "c1", title: "Maya Chen", participants: [], avatar: .monogram("MC"),
        preview: "See you at the standup, the notes are in the doc", previewSender: nil,
        lastAt: Date(timeIntervalSince1970: 1_800_000_000), unreadCount: 1, pinned: false, muted: false,
        typing: false, lastReaction: nil)

    /// Results come back in index order, with nil where the body gave none.
    @Test func concurrentMapKeepsIndexOrder() {
        let out = sidebarConcurrentMap(1_000) { $0 % 7 == 0 ? nil : $0 * 2 }
        #expect(out.count == 1_000)
        #expect(out.enumerated().allSatisfy { i, v in v == (i % 7 == 0 ? nil : i * 2) })
        #expect(sidebarConcurrentMap(0) { $0 }.isEmpty)
    }

    /// 2,000 row renders of one conversation on every core: no measurement is in two threads'
    /// hands at once (before: every thread drew from the one cached CTLine and CTTypesetter).
    @Test func textCacheLendsAMeasurementToOneThreadAtATime() {
        let cache = SidebarTextCache()
        let palette = SidebarShared(SidebarPalette.resolve(NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()))
        let summary = Self.summary
        let inUse = OSAllocatedUnfairLock(initialState: Set<ObjectIdentifier>())
        let overlaps = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 2_000) { _ in
            cache.withMeasured(summary, emphasized: false, palette: palette.value, generation: 0) { m in
                // The measurement's name line stands for it (its typesetter is lent with it).
                let line = ObjectIdentifier(m.name)
                let taken = inUse.withLock { $0.insert(line).inserted }
                if !taken { overlaps.withLock { $0 += 1 } }
                _ = CTLineGetTypographicBounds(m.name, nil, nil, nil)
                if let ts = m.preview { _ = CTTypesetterSuggestLineBreak(ts, 0, 120) }
                if taken { inUse.withLock { _ = $0.remove(line) } }
            }
        }
        #expect(overlaps.withLock { $0 } == 0)
        // The cache keeps the measurement: two later renders on one thread share it.
        let first = cache.withMeasured(summary, emphasized: false, palette: palette.value, generation: 0) { ObjectIdentifier($0.name) }
        let second = cache.withMeasured(summary, emphasized: false, palette: palette.value, generation: 0) { ObjectIdentifier($0.name) }
        #expect(first == second)
    }

    /// A request answers once from any number of threads, and never after the next keystroke
    /// cancelled it.
    @Test func searchRequestAnswersOnceAndNeverAfterCancel() {
        let answers = OSAllocatedUnfairLock(initialState: 0)
        let request = SidebarSearchRequest(query: "ma") { _ in answers.withLock { $0 += 1 } }
        DispatchQueue.concurrentPerform(iterations: 64) { _ in request.complete(nil) }
        #expect(answers.withLock { $0 } == 1)
        let cancelled = SidebarSearchRequest(query: "may") { _ in answers.withLock { $0 += 1 } }
        cancelled.cancel()
        cancelled.complete(SidebarSearchSection(title: "People", results: []))
        #expect(cancelled.isCancelled)
        #expect(answers.withLock { $0 } == 1)
    }
}

#if os(iOS)
import CmuxMobileLive
import Foundation
import Testing
import UIKit
@testable import CmuxMobileAgentChat

// g. chat_scroll_fill_ui   the fling of chat_scroll_fill on the real transcript list
//                          (`ChatTranscriptList`, its collection view, layout and cells, at an
//                          iPhone's 390 x 800 pt), not the store with estimated heights: p95 of each
//                          frame's time to a filled viewport. 16.7 ms (one frame).

extension InstantPerfTests {
    /// One fling up `log` on the transcript list, as `fling` does on the store: each 60 Hz frame
    /// moves the collection view (its delegate, the list, reads ahead as the app's does), lays it
    /// out and is timed to a filled viewport: the frame's own scroll and layout, the main actor's
    /// time on what landed since the last frame (the store taking an older page in and the list's
    /// reloads), and, when the viewport reached the list's top while older history remains (the
    /// loading row, nothing to read), the wait for rows; each frame passing during such a wait
    /// counts, at its own wait.
    ///
    /// `readsAhead: false` is the trigger before the read-ahead: the oldest row coming into view
    /// asks for the page (`willDisplay` of `session-start`, which the harness makes as the row
    /// enters the viewport). The source's one page held ahead is on in both.
    static func listFling(_ log: AgentChatLog, readsAhead: Bool) async throws
        -> (fills: [Double], blank: Int, pages: Int, screens: Double, uncovered: Int) {
        let fake = InstantPerfAcpmux(log)
        let hub = AcpmuxHub()
        await hub.bind(fake.channel(rtt: FlingReader.rtt, bytesPerSecond: FlingReader.bytesPerSecond))
        let store = AgentChatStore(source: hub.source(sessionID: "s1", summary: summary))
        let newest = try #require(log.lastTurn(before: log.count))
        let shown = await waitUntil { shows(store, newest) }
        try #require(shown, "the chat never showed \(newest)")
        let surface = AgentChatSurface()
        let list = ChatTranscriptList(store: store, surface: surface)
        list.readsAhead = readsAhead
        defer { withExtendedLifetime((store, list)) {} }
        let view = list.collectionView
        view.frame = CGRect(x: 0, y: 0, width: 390, height: FlingReader.viewport)
        list.boundsMayHaveChanged()
        view.layoutIfNeeded()
        // At the newest turn, then the reader takes over (the keyboard dock stops following).
        surface.following = false
        view.contentOffset.y = max(view.contentSize.height - view.bounds.height, -view.adjustedContentInset.top)
        view.layoutIfNeeded()

        let viewport = FlingReader.viewport
        var oldest = list.layout.items.first?.id
        var pages = 0
        var applied = store.earlierApplyTime
        var reloaded = list.reloadTime
        /// The main actor's time on what landed since the last look (an older page going into
        /// the store, the list's reloads), and whether older rows went in above.
        func absorb() -> Double {
            let nowApplied = store.earlierApplyTime, nowReloaded = list.reloadTime
            defer { applied = nowApplied; reloaded = nowReloaded }
            if let first = list.layout.items.first?.id, first != oldest {
                oldest = first
                pages += 1
            }
            return InstantPerfReport.ms(nowApplied - applied) + InstantPerfReport.ms(nowReloaded - reloaded)
        }
        var top: CGFloat { -view.adjustedContentInset.top }
        /// The old trigger: the oldest row (`session-start`) came into view.
        func oldTrigger() {
            guard !readsAhead, store.hasEarlierHistory, let start = list.layout.top(of: "session-start"),
                  start < view.contentOffset.y + view.bounds.height else { return }
            store.loadEarlier()
        }
        /// Rows in the viewport that have no cell after the layout pass (diagnostic, in the note).
        func uncoveredRows() -> Int {
            let visible = Set(view.indexPathsForVisibleItems)
            let laid = list.layout.layoutAttributesForElements(in: view.bounds) ?? []
            return laid.filter { !visible.contains($0.indexPath) }.count
        }
        oldTrigger()
        try await Task.sleep(for: .milliseconds(750)) // test: a person's pause before scrolling
        _ = absorb()

        var fills: [Double] = []
        var blank = 0
        var uncovered = 0
        var speed = FlingReader.flick
        var travelled = 0.0
        let frameMs = InstantPerfReport.ms(FlingReader.frame)
        let start = ContinuousClock.now
        var frame = 0
        while frame < FlingReader.frames {
            let due = start + FlingReader.frame * frame
            try await Task.sleep(until: due, clock: .continuous) // test: the display's next frame
            let woke = ContinuousClock.now
            let landing = absorb()
            let step = speed * frameMs / 1_000
            speed *= pow(FlingReader.decay, frameMs)
            if speed < FlingReader.reflick { speed = FlingReader.flick }
            let from = view.contentOffset.y
            // The scroll view's own step: its delegate (the list) reads ahead from here.
            view.contentOffset.y = max(from - step, top)
            view.layoutIfNeeded()
            oldTrigger()
            travelled += from - view.contentOffset.y
            uncovered += uncoveredRows()
            let pinned = view.contentOffset.y <= top + 0.5 && from - step < top
            if !pinned || !store.hasEarlierHistory {
                fills.append(InstantPerfReport.ms(woke.duration(to: .now)) + landing)
                if pinned { break } // the chat's start: the fling is over
                frame += 1
                continue
            }
            // The viewport reached the list's top with older history still on the Mac: the
            // loading row, nothing to read, until the page's rows go in above.
            let first = list.layout.items.first?.id
            let came = await waitUntil(.seconds(30)) { list.layout.items.first?.id != first || !store.hasEarlierHistory }
            #expect(came, "the older page never came")
            view.layoutIfNeeded()
            let filled = ContinuousClock.now
            var waiting = frame
            while start + FlingReader.frame * waiting < filled {
                fills.append(InstantPerfReport.ms((start + FlingReader.frame * waiting).duration(to: filled)))
                blank += 1
                waiting += 1
            }
            _ = absorb()
            if !came { break }
            frame = waiting
        }
        await hub.bind(nil)
        return (fills, blank, pages, travelled / viewport, uncovered)
    }

    @Test("chat_scroll_fill_ui")
    func chatScrollFillUI() async throws {
        struct Runs { var p95s: [Double] = []; var blank = 0, pages = 0, uncovered = 0; var worst = 0.0 }
        func flings(_ log: AgentChatLog, readsAhead: Bool, runs: Int) async throws -> Runs {
            var out = Runs()
            out.p95s = try await InstantPerfReport.sample(runs: runs) {
                let run = try await Self.listFling(log, readsAhead: readsAhead)
                out.blank += run.blank
                out.pages += run.pages
                out.uncovered += run.uncovered
                out.worst = max(out.worst, run.fills.max() ?? 0)
                return .microseconds(Int64((Self.p95(run.fills) * 1_000).rounded()))
            }
            return out
        }
        let runs = min(InstantPerfReport.defaultRuns, 3)
        // Before: the oldest row's display asks (the trigger until #41982), same harness.
        let smallBefore = try await flings(AgentChatFixture.smallPaged, readsAhead: false, runs: 1)
        let godBefore = try await flings(AgentChatFixture.god, readsAhead: false, runs: 1)
        let small = try await flings(AgentChatFixture.smallPaged, readsAhead: true, runs: runs)
        let god = try await flings(AgentChatFixture.god, readsAhead: true, runs: runs)
        let target = 16.7
        func fmt(_ value: Double) -> String { String(format: "%.2f", value) }
        InstantPerfReport.record(
            "chat_scroll_fill_ui", target: target, small: small.p95s, god: god.p95s,
            note: "the chat_scroll_fill fling on ChatTranscriptList (390 x 800 pt, real layout and cells) over a 50 ms, 4 MB/s link; "
                + "p95 per fling; blank-top frames: small \(small.blank), god \(god.blank) (warm-up included); pages shown: small \(small.pages), god \(god.pages); "
                + "worst frame: small \(fmt(small.worst)) ms, god \(fmt(god.worst)) ms; rows in the viewport with no cell: small \(small.uncovered), god \(god.uncovered); "
                + "before (oldest row's display asks, read-ahead off, 1 run after warm-up): p95 small \(fmt(InstantPerfReport.median(smallBefore.p95s))) ms, "
                + "god \(fmt(InstantPerfReport.median(godBefore.p95s))) ms, blank-top frames small \(smallBefore.blank), god \(godBefore.blank), "
                + "worst small \(fmt(smallBefore.worst)) ms, god \(fmt(godBefore.worst)) ms")
        // The gate (Leo, 2026-11-12: "scroll up history should be near-instant on iOS and
        // desktop"): no frame with a blank top on the list itself.
        #expect(small.blank == 0 && god.blank == 0, "the list's top was blank while scrolling: small \(small.blank), god \(god.blank) frames")
    }
}
#endif

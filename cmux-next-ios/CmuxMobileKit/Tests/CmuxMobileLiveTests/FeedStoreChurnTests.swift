import CmuxMobileDesign
import CmuxMobileFeed
import Foundation
import Observation
import Testing

/// The Feed re-renders on every `FeedStore` notification. The Mac re-reports
/// the same history on each tree change (several a second while an agent
/// works), so a write that changes nothing must not notify, re-save or count.
@MainActor
@Suite struct FeedStoreChurnTests {
    static func item(_ id: String, _ markdown: String = "body", ago: TimeInterval = 0, kind: FeedItem.Kind = .finished,
                     workspace: String = "w1") -> FeedItem {
        FeedItem(id: id, kind: kind, workspaceID: workspace, tabID: "t", agentName: "Codex", harness: "codex",
                 workspaceTitle: "cmux", markdown: markdown, quote: nil, createdAt: Date(timeIntervalSince1970: 1_000_000 - ago))
    }

    final class Flag: @unchecked Sendable { var fired = false }

    /// Runs `change` and reports whether `items` (or the lists the Feed reads) notified.
    func notifies(_ store: FeedStore, _ change: () -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking {
            _ = store.items
            _ = store.visibleItems
            _ = store.needsYouCount
            _ = store.unseenNewIDs
        } onChange: { flag.fired = true }
        change()
        return flag.fired
    }

    @Test func sameHistoryAgainDoesNotNotifyOrSave() {
        let store = FeedStore(items: [Self.item("a"), Self.item("b", ago: 5)])
        var saves = 0
        store.onItemsChange = { _ in saves += 1 }
        #expect(!notifies(store) { store.mergeHistory([Self.item("a"), Self.item("b", ago: 5)]) })
        #expect(!notifies(store) { store.upsert(Self.item("a"), atTop: true) })
        #expect(!notifies(store) { store.replaceAll([Self.item("b", ago: 5), Self.item("a")]) })
        #expect(saves == 0)
    }

    @Test func noOpMutationsDoNotNotify() {
        var read = Self.item("a")
        read.isRead = true
        let store = FeedStore(items: [read])
        #expect(!notifies(store) { store.markRead("a") })
        #expect(!notifies(store) { store.remove("missing") })
        #expect(!notifies(store) { store.clearUnseen() })
        #expect(!notifies(store) { store.resolveElsewhere("missing", text: "Answered") })
    }

    @Test func realChangesStillNotifyAndSave() {
        let store = FeedStore(items: [Self.item("a")])
        var saves = 0
        store.onItemsChange = { _ in saves += 1 }
        #expect(notifies(store) { store.mergeHistory([Self.item("a", "new text")]) })
        #expect(store.item(id: "a")?.markdown == "new text")
        #expect(notifies(store) { store.markRead("a") })
        #expect(notifies(store) { store.upsert(Self.item("c"), atTop: false) })
        #expect(store.unseenNewIDs == ["c"])
        #expect(saves == 3)
    }

    @Test func visibleItemsAndCountFollowItemsFilterAndMutes() {
        let store = FeedStore(items: [
            Self.item("done", ago: 1), Self.item("ask", ago: 2, kind: .needsInput), Self.item("fail", ago: 3, kind: .failed, workspace: "w2"),
        ])
        #expect(store.visibleItems.map(\.id) == ["done", "ask", "fail"])
        #expect(store.needsYouCount == 1)
        store.filter = .errors
        #expect(store.visibleItems.map(\.id) == ["fail"])
        store.filter = .all
        store.mutedWorkspaces.insert("w2")
        #expect(store.visibleItems.map(\.id) == ["done", "ask"])
        store.markDone("ask")
        #expect(store.visibleItems.map(\.id) == ["done"])
        #expect(store.needsYouCount == 0)
        store.undoDone()
        #expect(store.needsYouCount == 1)
        store.resolveElsewhere("ask", text: "Answered in the terminal")
        #expect(store.needsYouCount == 0)
    }

    /// An event read before and reported again by the Mac (unread) is marked
    /// read on the way in, and the stored list and the save see the read copy.
    @Test func reReportedReadEventIsReadInTheListAndTheSave() {
        let url = FileManager.default.temporaryDirectory.appending(path: "feed-read-\(UUID().uuidString).json")
        let marks = FeedReadMarks(url: url)
        defer { marks.remove() }
        marks.save(["a"])
        let store = FeedStore(items: [], readMarks: marks)
        var saved: [[FeedItem]] = []
        store.onItemsChange = { saved.append($0) }
        store.mergeHistory([Self.item("a")])
        #expect(store.visibleItems.first?.isRead == true)
        #expect(store.items.first?.isRead == true)
        #expect(saved.count == 1)
        #expect(saved.last?.first?.isRead == true)
    }

    @Test func archiveSavesInBackgroundAndRemoveWinsOverQueuedWrites() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "feed-archive-\(UUID().uuidString).json")
        let archive = FeedArchive(url: url)
        defer { archive.remove() }
        archive.saveInBackground([Self.item("a"), Self.item("b", ago: 1)])
        #expect(archive.load().map(\.id) == ["a", "b"])
        for index in 0..<20 { archive.saveInBackground([Self.item("x\(index)")]) }
        archive.remove()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(archive.load().isEmpty)
    }
}

@Suite struct FrameIntervalStatsTests {
    @Test func percentilesHitchesAndDroppedFrames() {
        // 96 smooth frames, 3 one-frame drops (33.3 ms), 1 three-frame drop (66.7 ms).
        let frame = 1.0 / 60
        let intervals = Array(repeating: frame, count: 96) + [frame * 2, frame * 2, frame * 2, frame * 4]
        let stats = FrameIntervalStats(label: "t", intervals: intervals, expected: frame)
        #expect(stats.frames == 100)
        #expect(abs(stats.p50Ms - 16.67) < 0.01)
        #expect(abs(stats.p95Ms - 16.67) < 0.01)
        #expect(abs(stats.p99Ms - 33.33) < 0.01)
        #expect(abs(stats.maxMs - 66.67) < 0.01)
        #expect(stats.hitches == 4)
        #expect(stats.droppedFrames == 6)
        // Late time: 3 x 16.67 + 50 = 100 ms over 106 frames (1.767 s).
        #expect(abs(stats.durationSeconds - 106.0 / 60) < 0.01)
        #expect(abs(stats.hitchMsPerSecond - 100 / (106.0 / 60)) < 0.5)
    }

    @Test func emptyWindow() {
        let stats = FrameIntervalStats(label: "t", intervals: [], expected: 1.0 / 120)
        #expect(stats.frames == 0 && stats.hitches == 0 && stats.maxMs == 0 && stats.hitchMsPerSecond == 0)
    }
}

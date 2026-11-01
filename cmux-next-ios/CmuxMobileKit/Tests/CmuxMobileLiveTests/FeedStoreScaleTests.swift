@testable import CmuxMobileFeed
import Foundation
import Observation
import Testing
@testable import CmuxMobileLive

/// The Feed's store work per write must not grow with the history behind it: lookups by id,
/// read marks, the Mac's reads and the ledger's echo check ran as scans (several a second
/// while agents work, on the main thread, under a scrolling Feed).
@MainActor
@Suite struct FeedStoreScaleTests {
    static func item(_ id: String, ago: TimeInterval = 0, read: Bool = false) -> FeedItem {
        var item = FeedItem(id: id, kind: .finished, workspaceID: "w1", tabID: "t", agentName: "Codex", harness: "codex",
                            workspaceTitle: "cmux", markdown: "body", quote: nil, createdAt: Date(timeIntervalSince1970: 1_000_000 - ago))
        item.isRead = read
        return item
    }

    @Test func lookupsByIDFollowEveryKindOfWrite() {
        let store = FeedStore(items: (0..<50).map { Self.item("i\($0)", ago: Double($0)) })
        #expect(store.item(id: "i10")?.id == "i10")
        store.insert(Self.item("new", ago: -1), atTop: true)
        #expect(store.item(id: "new")?.id == "new")
        #expect(store.item(id: "i10")?.id == "i10")
        store.mergeHistory([Self.item("old", ago: 500), Self.item("i3", ago: 3)])
        #expect(store.item(id: "old")?.id == "old")
        #expect(store.item(id: "i49")?.id == "i49")
        store.remove("i10")
        #expect(store.item(id: "i10") == nil)
        #expect(store.item(id: "i11")?.id == "i11")
        store.markRead("i11")
        #expect(store.item(id: "i11")?.isRead == true)
    }

    @Test func theMacsReadsLandInOneWrite() {
        let store = FeedStore(items: (0..<20).map { Self.item("i\($0)", ago: Double($0)) })
        var writes = 0
        store.onItemsChange = { _ in writes += 1 }
        store.markRead(["i1", "i2", "i3", "missing"])
        #expect(writes == 1)
        #expect(store.items.filter(\.isRead).map(\.id).sorted() == ["i1", "i2", "i3"])
        store.markRead(["i1", "i2"])
        #expect(writes == 1)
    }

    /// Sign-out then sign-in again before the disk queue drains: the marks saved after the
    /// removal are the ones on disk (an earlier write must not take them, then be deleted).
    @Test func aSaveAfterARemovalLandsWhenAllThreeWereQueued() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "readmarks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let marks = FeedReadMarks(url: url)
        FeedReadMarks.queue.suspend()
        marks.save(["a"])
        marks.remove()
        marks.save(["b"])
        FeedReadMarks.queue.resume()
        FeedReadMarks.flush()
        #expect(marks.load() == ["b"])
        let onDisk = try? JSONDecoder().decode([String].self, from: Data(contentsOf: url))
        #expect(onDisk == ["b"])
    }

    @Test func readMarksSaveOffTheCallerAndReloadInOrder() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "readmarks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let marks = FeedReadMarks(url: url)
        let store = FeedStore(items: [Self.item("a"), Self.item("b", ago: 1)], readMarks: marks)
        store.markRead("a")
        store.markRead("b")
        store.markUnread("a")
        // `load` sees the newest marks at once (written or still queued), without waiting.
        #expect(marks.load() == ["b"])
        FeedReadMarks.flush()
        let onDisk = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
        #expect(onDisk == ["b"])
        let reopened = FeedStore(items: [Self.item("a"), Self.item("b", ago: 1)], readMarks: marks)
        #expect(reopened.item(id: "b")?.isRead == true)
        #expect(reopened.item(id: "a")?.isRead == false)
        marks.remove()
        #expect(marks.load() == [])
        FeedReadMarks.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// The echo set matches the definition it replaced (a terminal row within the window of an
    /// agent row on its surface), including rows just inside and just outside the window.
    @Test func echoesMatchTheOldPairwiseCheck() {
        func entry(_ id: String, _ source: String, surface: Int, at seconds: Double) -> TerminalFeed.Entry {
            TerminalFeed.Entry(json: ["id": id, "title": "t", "body": "b", "source": source, "surface": surface,
                                      "created_at_ms": Int(seconds * 1000)])!
        }
        let window = TerminalFeed.echoWindow
        let entries = [
            entry("a1", "agent", surface: 1, at: 100),
            entry("t1", "terminal", surface: 1, at: 100 + window),
            entry("t2", "terminal", surface: 1, at: 100 + window + 1),
            entry("t3", "terminal", surface: 2, at: 101),
            entry("a2", "agent", surface: 2, at: 300),
            entry("t4", "terminal", surface: 2, at: 300 - window),
            entry("a3", "agent", surface: 1, at: 400),
            entry("t5", "terminal", surface: 1, at: 395),
        ].sorted { $0.createdAt < $1.createdAt }
        let pairwise = Set(entries.filter { entry in
            entry.source == "terminal" && entries.contains { other in
                other.source == "agent" && other.surface == entry.surface
                    && abs(other.createdAt.timeIntervalSince(entry.createdAt)) <= window
            }
        }.map(\.id))
        #expect(TerminalFeed.echoes(in: entries) == pairwise)
        #expect(pairwise == ["t1", "t4", "t5"])
    }
}

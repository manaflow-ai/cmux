import AppKit
import CoreGraphics
import Dispatch
import Foundation
import os
import Testing
@testable import MessagesLabHome

/// The transcript's measure, parse, decode and long-text caches, used from the row threads at once
/// (p10-stability-055): they were `@unchecked Sendable` classes over an NSLock and are now checked
/// `Sendable` with one lock state each. Every concurrent lookup is counted once, a byte budget holds,
/// an attributed string is built once per side, and the flight recorder's policy reads what the app set.
@Suite struct CatalystCachesSendableTests {
    static let threads = 8

    private static func message(_ i: Int) -> MessagesLabHome.Message {
        MessagesLabHome.Message(id: "m\(i)", senderId: "p\(i % 3)", sentAt: "2026-10-26T12:00:00-07:00",
                                parts: [.text("Message \(i) with a few words to measure", runs: [])],
                                replyTo: nil, status: nil, edits: nil, retractedAt: nil, reactions: [])
    }

    /// Each lookup bumps exactly one counter (a hit, a miss, a reuse or an estimate), and every key
    /// measured on any thread is stored: no lost update under concurrent measuring.
    @Test func measureCacheCountsEveryConcurrentLookup() {
        let cache = MeasureCache()
        let messages = (0..<24).map(Self.message)
        let widths: [CGFloat] = [320, 480, 760]
        let rounds = 20
        DispatchQueue.concurrentPerform(iterations: Self.threads) { t in
            for r in 0..<rounds {
                for (i, m) in messages.enumerated() {
                    _ = cache.size(m, 0, width: widths[(i + t + r) % widths.count], scale: 2)
                }
            }
        }
        let calls = Self.threads * rounds * messages.count
        #expect(cache.hits + cache.misses + cache.reuses + cache.estimates == calls)
        #expect(cache.count == messages.count * widths.count)
    }

    /// Concurrent show-source toggles land, each one.
    @Test func markdownStoreKeepsEveryConcurrentSourceToggle() {
        let store = MarkdownStore()
        let ids = (0..<200).map { "src\($0)" }
        DispatchQueue.concurrentPerform(iterations: Self.threads) { t in
            for (i, id) in ids.enumerated() where i % Self.threads == t { store.setShowsSource(id, true) }
        }
        #expect(ids.allSatisfy(store.showsSource))
        DispatchQueue.concurrentPerform(iterations: Self.threads) { t in
            for (i, id) in ids.enumerated() where i % Self.threads == t && i % 2 == 0 { store.setShowsSource(id, false) }
        }
        #expect(ids.enumerated().allSatisfy { i, id in store.showsSource(id) == (i % 2 == 1) })
    }

    /// The same text parsed on many threads gives one document, and a stream's longer text extends it.
    @Test func markdownStoreParsesTheSameDocumentOnEveryThread() {
        let store = MarkdownStore()
        let text = "# Title\n\n- one\n- two\n\n```swift\nlet x = 1\n```\n"
        let docs = OSAllocatedUnfairLock(initialState: [MDDocument]())
        DispatchQueue.concurrentPerform(iterations: Self.threads) { _ in
            let d = store.document(text)
            docs.withLock { $0.append(d) }
        }
        let all = docs.withLock { $0 }
        #expect(all.count == Self.threads)
        #expect(Set(all).count == 1)
        #expect(store.fullParses >= 1)
        let longer = store.document(text + "\nMore text after the fence.\n")
        #expect(longer.blocks.count > (all.first?.blocks.count ?? 0))
    }

    private static func image(side: Int) -> HomeShared<UIImage>? {
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue),
              let cg = ctx.makeImage() else { return nil }
        return HomeShared(UIImage(cgImage: cg, scale: 1))
    }

    /// Stores from many threads keep the byte count equal to the images held, under the budget.
    @Test func mediaCacheKeepsItsByteCountUnderConcurrentStores() throws {
        let cache = MediaCache()
        let shared = try #require(Self.image(side: 64))
        let each = try #require(shared.value.cgImage.map { $0.bytesPerRow * $0.height })
        cache.budget = each * 40
        DispatchQueue.concurrentPerform(iterations: Self.threads) { t in
            for i in 0..<50 { cache.store("img\(t)-\(i)@2.0", shared.value) }
        }
        #expect(cache.bytes == cache.count * each)
        #expect(cache.bytes <= cache.budget)
        #expect(cache.count > 0)
        let kept = (0..<Self.threads).flatMap { t in (0..<50).map { "img\(t)-\($0)" } }
        cache.evict(refs: Set(kept), scale: 2.0)
        #expect(cache.count == 0)
        #expect(cache.bytes == 0)
    }

    /// Two renderers asking for the same block's drawing attributes at once draw one string per side.
    @Test func blockLayoutBuildsOneAttributedStringPerSide() {
        let block = BlockLayout(string: "A line with a link https://example.com and more words\nsecond line" as NSString,
                                column: 300, final: true)
        let seen = OSAllocatedUnfairLock(initialState: [Bool: Set<ObjectIdentifier>]())
        DispatchQueue.concurrentPerform(iterations: Self.threads * 4) { i in
            let outgoing = i % 2 == 0
            let id = ObjectIdentifier(block.attributed(outgoing: outgoing))
            seen.withLock { $0[outgoing, default: []].insert(id) }
        }
        let bySide = seen.withLock { $0 }
        #expect(bySide[true]?.count == 1)
        #expect(bySide[false]?.count == 1)
        #expect(block.lineCount == block.lines.count)
    }

    /// The same long text laid out on many threads ends with one index and one layout per width.
    @Test func longTextStoreKeepsOneIndexAndLayoutAcrossThreads() {
        let store = LongTextStore()
        let text = (0..<600).map { "line \($0) of a long message with some words in it" }.joined(separator: "\n")
        #expect(LongText.isLong(text))
        DispatchQueue.concurrentPerform(iterations: Self.threads) { t in
            _ = store.layout(text, width: t % 2 == 0 ? 760 : 520)
        }
        #expect(store.indexCount == 1)
        let first = store.layout(text, width: 760)
        #expect(store.layout(text, width: 760) === first)
        #expect(!first.retired)
        #expect(first.totalLines >= 600)
    }

    /// Concurrent inserts never grow the LRU past its capacity, and a key set last is found.
    @Test func mdLRUStaysWithinItsCapacity() {
        let lru = MDLRU<Int, Int>(capacity: 64)
        DispatchQueue.concurrentPerform(iterations: Self.threads) { t in
            for i in 0..<500 { lru.set(t * 1000 + i, i) }
        }
        #expect(lru.count <= 64)
        lru.set(-1, 7)
        #expect(lru.get(-1) == 7)
    }

    /// The app's policy (CmuxNextHome's HomeFlightRecording.install) is what the recorder reads, from any thread.
    @Test func flightRecorderReadsThePolicyTheAppSet() async {
        let folder = HomeFlightRecorder.logFolder
        defer { HomeFlightRecorder.logFolder = folder }
        HomeFlightRecorder.logFolder = "cmux-policy-test"
        let read: String = await withCheckedContinuation { done in
            DispatchQueue(label: "catalyst-caches.flight", qos: .utility).async { done.resume(returning: HomeFlightRecorder.logFolder) }
        }
        #expect(read == "cmux-policy-test")
        #expect(!HomeFlightRecorder.isEnabled(), "off until the app turns it on")
        #expect(!HomeFlightRecorder.capturesWindow())
    }
}

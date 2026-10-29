import AppKit
import CoreGraphics
import Dispatch
import Foundation
import os
import Testing
@testable import MessagesLabHome

/// The transcript's measure, parse, decode and long-text caches, used from the row threads at once:
/// they were `@unchecked Sendable` classes over an NSLock and are now checked
/// `Sendable` with one `Mutex` state each. Every concurrent lookup is counted once, a byte budget holds,
/// an attributed string is built once per side, a dropped long-text layout is retired and every index has
/// its own lineage.
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
        guard let ctx = CGContext.ownedBitmap(width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
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

    /// The rows lay out one long text at six widths on many threads while the measure queue runs its blocks:
    /// at most three layouts stay registered, and every other layout a caller got is retired (its queued
    /// measuring stops). Before the fix `retired` was a plain var the measure queue read while a layout or
    /// register call wrote it (TSan: data race), and two threads that laid out the same width at once both
    /// registered theirs, the first one dropped but never retired.
    @Test func longTextStoreRetiresEveryDroppedLayoutUnderConcurrentLayout() {
        let store = LongTextStore()
        let text = (0..<2000).map { "line \($0) of a long message with some words in it" }.joined(separator: "\n")
        let widths: [CGFloat] = [360, 440, 520, 600, 680, 760]
        let got = OSAllocatedUnfairLock(initialState: [LongTextLayout]())
        DispatchQueue.concurrentPerform(iterations: Self.threads) { t in
            for r in 0..<12 {
                let l = store.layout(text, width: widths[(t + r) % widths.count])
                got.withLock { $0.append(l) }
            }
        }
        let registered = store.registeredLayouts(text)
        let live = Set(registered.map(ObjectIdentifier.init))
        #expect(!registered.isEmpty)
        #expect(registered.count <= 3)
        #expect(registered.allSatisfy { !$0.retired })
        let all = got.withLock { $0 }
        #expect(all.count == Self.threads * 12)
        let unretired = all.filter { !live.contains(ObjectIdentifier($0)) && !$0.retired }
        #expect(unretired.isEmpty, "\(unretired.count) dropped layouts still measuring")
        LongTextLayout.measureQueue.waitUntilAllOperationsAreFinished()
    }

    /// Distinct texts indexed on many threads at once get distinct lineages (a lineage keys the block and
    /// tile caches, so two texts sharing one draw each other's tiles). Before the fix the serial was bumped
    /// outside the store's lock (TSan: data race; a lost update gives two indexes one lineage).
    @Test func longTextStoreGivesEveryConcurrentIndexItsOwnLineage() {
        let store = LongTextStore()
        let body = (0..<300).map { "line \($0) of a long message with some words in it" }.joined(separator: "\n")
        let texts = (0..<LongTextStore.maxIndexes).map { "text \($0) starts here\n" + body }
        let indexes = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: LongTextIndex]())
        DispatchQueue.concurrentPerform(iterations: Self.threads) { t in
            for k in 0..<texts.count {
                let i = store.layout(texts[(k + t) % texts.count], width: 520).index
                indexes.withLock { $0[ObjectIdentifier(i)] = i }
            }
        }
        let built = indexes.withLock { Array($0.values) }
        #expect(built.count >= texts.count)
        #expect(Set(built.map(\.lineage)).count == built.count)
        LongTextLayout.measureQueue.waitUntilAllOperationsAreFinished()
    }
}

/// The flight recorder's policy (CmuxNextHome's HomeFlightRecording.install sets it at launch; the recorder
/// reads it after a send and on its dump queue). Many threads read it while one writes it: before the fix the
/// three statics were `nonisolated(unsafe)` vars (TSan: data race). The writer stores the values already set,
/// so no other test sees a changed policy; serialized because it writes process-global state.
@Suite(.serialized) struct HomeFlightRecorderPolicyTests {
    @Test func policyReadsAndWritesFromManyThreadsAtOnce() {
        let enabled = HomeFlightRecorder.isEnabled
        let captures = HomeFlightRecorder.capturesWindow
        let folder = HomeFlightRecorder.logFolder
        let on = enabled(), capturing = captures()
        let mismatches = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 8) { t in
            for _ in 0..<2000 {
                if t == 0 {
                    HomeFlightRecorder.isEnabled = enabled
                    HomeFlightRecorder.capturesWindow = captures
                    HomeFlightRecorder.logFolder = folder
                } else if HomeFlightRecorder.isEnabled() != on || HomeFlightRecorder.capturesWindow() != capturing
                    || HomeFlightRecorder.logFolder != folder {
                    mismatches.withLock { $0 += 1 }
                }
            }
        }
        #expect(mismatches.withLock { $0 } == 0)
    }
}

import CoreGraphics
import Dispatch
import Foundation
import os
import Testing
@testable import MessagesLabHome

/// The catalyst caches that row drawing reaches from the render queues and the main thread at once
/// (p10-stability-041): every miss and hit from many threads gives what one thread computes, and the process
/// stays up. Each cache is lock-owned; the bubble outline cache had no lock before, so many threads that miss
/// at once wrote one dictionary (a trap, or a report under `--sanitize=thread`).
@Suite struct CatalystSharedCachesConcurrencyTests {
    /// Results written by index from the workers.
    private final class Results<Value: Sendable>: Sendable {
        private let values = OSAllocatedUnfairLock<[Int: Value]>(initialState: [:])
        func set(_ i: Int, _ value: Value) { values.withLock { $0[i] = value } }
        var all: [Int: Value] { values.withLock { $0 } }
    }

    private static let workers = 4096

    @Test func bubbleOutlinesMissedFromManyThreadsAreTheOutlinesOfOneThread() {
        // Every size is new to the cache (a miss writes it), and more than 2000 of them make the cache clear
        // itself while other threads read and write it.
        @Sendable func size(_ i: Int) -> CGSize { CGSize(width: 1000 + CGFloat(i) / 8, height: 30 + CGFloat(i % 5) * 16) }
        let got = Results<CGRect>()
        DispatchQueue.concurrentPerform(iterations: Self.workers) { i in
            got.set(i, BubblePath.cached(size: size(i), outgoing: i % 2 == 0, tail: i % 3 == 0).boundingBoxOfPath)
        }
        let all = got.all
        #expect(all.count == Self.workers)
        for i in 0..<Self.workers {
            let fresh = BubblePath.make(body: CGRect(origin: .zero, size: size(i)), outgoing: i % 2 == 0, tail: i % 3 == 0)
            #expect(all[i] == fresh.cgPath.boundingBoxOfPath, "outline \(i)")
        }
    }

    @Test func markdownDocumentsParsedFromManyThreadsAreFreshParses() {
        let store = MarkdownStore()
        // Fixed-width ids: no text is a prefix of another (the stream path has its own test).
        @Sendable func text(_ i: Int) -> String { String(format: "# Title %05ld\n\n- **item** `%05ld`\n- [link](https://cmux.dev/%05ld)\n", i, i, i) }
        let got = Results<MDDocument>()
        DispatchQueue.concurrentPerform(iterations: 512) { i in got.set(i, store.document(text(i % 256))) }
        let all = got.all
        #expect(all.count == 512)
        for i in 0..<512 { #expect(all[i] == Markdown.parse(text(i % 256)), "document \(i)") }
        #expect(store.fullParses + store.tailParses >= 256)
    }

    @Test func timestampsParsedFromManyThreadsAreTheirInstants() {
        @Sendable func stamp(_ i: Int) -> String { String(format: "2026-%02ld-%02ldT%02ld:%02ld:%02ld-07:00", 1 + i % 12, 1 + i % 28, i % 24, i % 60, (i / 60) % 60) }
        let got = Results<Date>()
        DispatchQueue.concurrentPerform(iterations: Self.workers) { i in got.set(i, Instant.parse(stamp(i))) }
        let all = got.all
        for i in 0..<Self.workers { #expect(all[i] == Instant.fast(stamp(i)), "stamp \(i)") }
    }

    @Test func settlingTimesFromManyThreadsMatchTheCachedOnes() {
        @Sendable func spring(_ i: Int) -> Spring { Spring(duration: 0.2 + Double(i) / 10_000, bounce: Double(i % 4) / 10) }
        let got = Results<Double>()
        DispatchQueue.concurrentPerform(iterations: 1024) { i in got.set(i, spring(i % 512).settlingTime()) }
        let all = got.all
        for i in 0..<1024 { #expect(all[i] == spring(i % 512).settlingTime(), "spring \(i)") }
    }

    @Test func decodedImagesStoredAndEvictedFromManyThreadsKeepTheByteCount() throws {
        let cache = MediaCache()
        let ctx = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(ctx.makeImage())
        let each = image.bytesPerRow * image.height
        let refs = (0..<1024).map { "ref-\($0)" }
        DispatchQueue.concurrentPerform(iterations: refs.count) { i in
            cache.store(refs[i] + "@2.0", UIImage(cgImage: image, scale: 2))
            _ = cache.cached(refs[(i * 7) % refs.count] + "@2.0")
        }
        #expect(cache.count == refs.count)
        #expect(cache.bytes == refs.count * each)
        DispatchQueue.concurrentPerform(iterations: 8) { k in
            cache.evict(refs: Set(refs.enumerated().filter { $0.offset % 8 == k }.map(\.element)), scale: 2)
        }
        #expect(cache.count == 0)
        #expect(cache.bytes == 0)
    }
}

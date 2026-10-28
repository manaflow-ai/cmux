import CoreGraphics
import Dispatch
import Foundation
import ImageIO
import os
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The catalyst caches that row drawing reaches from the render queues and the main thread at once:
/// every miss and hit from many threads gives what one thread computes, and the process
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

    @Test func settlingTimesFromManyThreadsAreFreshSearches() {
        // Durations no other test uses: the concurrent pass misses and writes the cache from many threads.
        @Sendable func spring(_ i: Int) -> Spring { Spring(duration: 0.2 + Double(i) / 10_000 + 1e-7, bounce: Double(i % 4) / 10) }
        let got = Results<Double>()
        DispatchQueue.concurrentPerform(iterations: 1024) { i in got.set(i, spring(i % 512).settlingTime()) }
        let all = got.all
        // Compared with the search itself, not with the cache the pass wrote.
        for i in 0..<1024 { #expect(all[i] == spring(i % 512).searchSettlingTime(epsilon: 2e-4), "spring \(i)") }
    }

    /// One soft-edge template, as the pixels it holds.
    private struct SoftEdgeImage: Sendable, Equatable {
        let pixels: Data?, width: Int, height: Int, center: CGRect
        init?(_ m: SoftBalloon.Mask?) {
            guard let m else { return nil }
            pixels = m.image.dataProvider?.data as Data?
            width = m.image.width; height = m.image.height; center = m.center
        }
    }

    /// A 1-line outgoing text part: the parts that get the soft edge (RowDraw.insetApplies: macOS 27).
    private static func outgoingLine() -> PartRow {
        PartRow(ref: PartRef(messageId: "soft", partIndex: 0), part: .text("x", runs: []), outgoing: true, tail: false,
                reactions: [], failed: false, size: CGSize(width: 30, height: 30), text: nil, connectorRoot: nil)
    }
    static let softEdgeApplies = RowDraw.insetApplies(outgoingLine())

    @Test(.enabled(if: CatalystSharedCachesConcurrencyTests.softEdgeApplies))
    func softEdgeTemplatesMissedFromManyThreadsAreFreshTemplates() {
        // Narrow balloons (under the 40 pt of caps) get one template per width and left phase: every frame below is a
        // new key, so the concurrent pass misses and writes the template cache from many threads (no lock before).
        @Sendable func frame(_ i: Int, width: CGFloat) -> CGRect { CGRect(x: 100 + CGFloat(i) / 2000, y: 0, width: width, height: 30) }
        let got = Results<SoftEdgeImage?>()
        DispatchQueue.concurrentPerform(iterations: 150) { i in
            got.set(i, SoftEdgeImage(SoftBalloon.mask(frame: frame(i, width: 30), row: Self.outgoingLine(), scale: 2)))
        }
        let all = got.all
        #expect(all.count == 150)
        // 250 other narrow templates: past 200 entries the cache drops every narrow one, so the 150 above are made
        // again below, on one thread.
        for j in 0..<250 { _ = SoftBalloon.mask(frame: frame(j, width: 25), row: Self.outgoingLine(), scale: 2) }
        for i in 0..<150 {
            let fresh = SoftEdgeImage(SoftBalloon.mask(frame: frame(i, width: 30), row: Self.outgoingLine(), scale: 2))
            #expect(fresh != nil)
            #expect(all[i] == fresh, "template \(i)")
        }
    }

    @Test(.enabled(if: CatalystSharedCachesConcurrencyTests.softEdgeApplies))
    @MainActor func crispCopyScopeHoldsOnlyOnTheMainThread() throws {
        let ctx = try #require(CGContext.ownedBitmap(width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let body = CGRect(x: 20, y: 20, width: 120, height: 30)
        @Sendable func softEdge(_ ctx: CGContext) -> Bool {
            ctx.saveGState(); defer { ctx.restoreGState() }
            return SoftBalloon.clip(ctx, frame: body, row: Self.outgoingLine(), scale: 2)
        }
        #expect(softEdge(ctx))
        let renderQueue = DispatchQueue(label: "test.row-bitmaps", qos: .userInitiated)
        let offMain = Results<Bool>()
        var onMain: Bool?
        SoftBalloon.withCrispCopy(true) {
            onMain = softEdge(ctx)
            // A row bitmap drawn on a render queue while main copies a just-sent row: the main thread's scope is not
            // its scope (it read main's flag before, and drew a crisp edge into the cached bitmap).
            let done = DispatchSemaphore(value: 0)
            renderQueue.async {
                let bitmap = CGContext.ownedBitmap(width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                offMain.set(0, bitmap.map(softEdge) ?? false)
                done.signal()
            }
            _ = done.wait(timeout: .now() + 30)
        }
        #expect(onMain == false)
        #expect(offMain.all[0] == true)
        #expect(softEdge(ctx))
    }

    @Test func markdownScrollOffsetsSetFromManyThreadsReadBack() {
        // Identities no layout uses (a layout's is a hash of its source and width).
        @Sendable func identity(_ i: Int) -> Int { Int.min + 7_041 + i / 4 }
        DispatchQueue.concurrentPerform(iterations: 2048) { i in
            MarkdownScroll.set(identity: identity(i), region: i % 4, CGFloat(i))
            _ = MarkdownScroll.offset(identity: identity((i * 7) % 2048), region: i % 4)
        }
        for i in 0..<2048 { #expect(MarkdownScroll.offset(identity: identity(i), region: i % 4) == CGFloat(i), "offset \(i)") }
        #expect(MarkdownScroll.all(identity(0)) == [0: 0, 1: 1, 2: 2, 3: 3])
    }

    @Test func decodedImagesStoredAndEvictedFromManyThreadsKeepTheByteCount() throws {
        let cache = MediaCache()
        let ctx = try #require(CGContext.ownedBitmap(width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
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

/// The media thumbnails (main thread): a request for a thumbnail that is already decoding waits for it too.
@MainActor @Suite struct CatalystThumbnailRequestTests {
    @Test(.timeLimit(.minutes(1)))
    func aRequestWhileTheThumbnailDecodesGetsItsCompletion() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctx = try #require(CGContext.ownedBitmap(width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try #require(ctx.makeImage())
        let file = dir.appendingPathComponent("photo.png")
        let dest = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        let ref = file.absoluteString
        #expect(MediaCache.thumb(ref) == nil)
        // The scroll prefetcher asks first, with no completion; a cell's placeholder asks while that decode runs.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            MediaCache.requestThumb(ref)
            MediaCache.requestThumb(ref) { done.resume() }
        }
        #expect(MediaCache.thumb(ref) != nil)
    }
}

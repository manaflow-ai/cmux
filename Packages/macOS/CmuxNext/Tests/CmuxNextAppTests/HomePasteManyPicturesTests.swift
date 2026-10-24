import AppKit
import CmuxHomeCore
@testable import CmuxNextHome
import ImageIO
@testable import MessagesLabHome
import Testing
import UniformTypeIdentifiers

/// Pasting several pictures into the Chief's message box (Lawrence 2026-10-23, msg 11952: it lags).
/// Measured on the fleet (MessagesLab's HomeComposerPasteRebuildCostTests, 10 screenshots): the main
/// thread never stalled past 4.5 ms; the time went to each picture's prepare (copy and hash into
/// the blob cache, about 20 ms) and bubble picture (about 11 ms), off the main actor but one picture
/// after the other, so the last of 10 showed after about 340 ms. The intake now prepares up to
/// a few pictures at once and puts them in the box in the
/// paste's order.
///
/// Drives the real `HomeNativeTranscriptView` over a `HomeStore` on the mock owner, through the
/// paste's own intake (`handlePaste`), in a window that is never ordered front.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct HomePasteManyPicturesTests {
    /// Pasteboard contents as a value (a ci-step mini has no pasteboard server); `items` are its pictures.
    struct Board: HomePasteboardContents {
        var types: [NSPasteboard.PasteboardType: Data] = [:]
        var items: [any HomePasteboardContents] = []
        var fileURLs: [URL] { [] }
        func hasType(_ wanted: [NSPasteboard.PasteboardType]) -> Bool { wanted.contains { types[$0] != nil } }
        func data(forType type: NSPasteboard.PasteboardType) -> Data? { types[type] }
        func string(forType type: NSPasteboard.PasteboardType) -> String? { nil }
    }

    /// The store's prepare behind a gate: each call waits until the test opens it, so the test sees
    /// how many prepares run at once and can let them finish in any order.
    @MainActor final class GatedPreparer: HomeAttachmentPreparing {
        let store: HomeStore
        private(set) var started: [Data] = []
        /// Each picture's hash once its prepare finished.
        private(set) var hashes: [Data: String] = [:]
        private var gates: [Data: CheckedContinuation<Void, Never>] = [:]
        private var open: Set<Data> = []

        init(store: HomeStore) { self.store = store }

        func prepareAttachment(fileURL: URL, keepLocation: Bool) async throws -> LocalAttachment {
            try await store.prepareAttachment(fileURL: fileURL, keepLocation: keepLocation)
        }

        func prepareAttachment(data: Data, typeIdentifier: String, keepLocation: Bool) async throws -> LocalAttachment {
            started.append(data)
            if !open.contains(data) { await withCheckedContinuation { gates[data] = $0 } }
            let prepared = try await store.prepareAttachment(data: data, typeIdentifier: typeIdentifier, keepLocation: keepLocation)
            hashes[data] = prepared.ref.hash
            return prepared
        }

        /// Lets the prepare of DATA finish (now, or as soon as it starts).
        func release(_ data: Data) {
            open.insert(data)
            gates.removeValue(forKey: data)?.resume()
        }
    }

    struct Home {
        let window: NSWindow
        let store: HomeStore
        let view: HomeNativeTranscriptView
        let blobs: URL
        func close() {
            view.stop()
            store.stop()
            try? FileManager.default.removeItem(at: blobs)
        }
    }

    private func home() async throws -> Home {
        let source = MockHomeSource(options: .immediate)
        let blobs = FileManager.default.temporaryDirectory.appendingPathComponent("home-paste-many-\(UUID().uuidString)", isDirectory: true)
        let store = HomeStore(source: source, blobCacheDirectory: blobs)
        store.start()
        let inbox = try await source.inbox()
        let chief = await source.chief.id
        let id = try #require((inbox.conversations.first { $0.participants.contains { $0.id == chief } } ?? inbox.conversations.first)?.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = HomeNativeTranscriptView(store: store, conversation: id, me: inbox.me.id)
        view.frame = window.contentView!.bounds
        window.contentView!.addSubview(view)
        await view.binding.opened()
        view.layoutSubtreeIfNeeded()
        return Home(window: window, store: store, view: view, blobs: blobs)
    }

    /// A screenshot-sized PNG (1412 x 1106 px), a different picture per INDEX (its hash differs).
    private static func screenshot(_ index: Int) throws -> Data {
        let w = 1412, h = 1106
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: CGFloat(index % 7) / 7, green: 0.4, blue: CGFloat(index % 3) / 3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 20 + index * 40, y: 60, width: 300, height: 50))
        let image = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// Several pictures copied together: one item each.
    private static func board(_ pictures: [Data]) -> Board {
        Board(types: [.png: pictures[0]], items: pictures.map { Board(types: [.png: $0]) })
    }

    private func until(_ limit: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    }

    private static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

    /// Five pictures pasted together: at least four prepare at once (not each after the one before),
    /// and they land in the box in the paste's order even when the last one is ready first.
    @Test func picturesPastedTogetherArePreparedAtOnceAndKeepTheirOrder() async throws {
        let h = try await home()
        defer { h.close() }
        let gated = GatedPreparer(store: h.store)
        h.view.attachmentPreparer = gated
        let pictures = try (0..<5).map(Self.screenshot)
        #expect(h.view.handlePaste(Self.board(pictures)))
        await until { gated.started.count >= 4 }
        let atOnce = gated.started.count
        #expect(atOnce >= 4, "\(atOnce) of \(pictures.count) prepares were running at once (want at least 4)")
        // The last picture is ready first, the first one last; then every one in turn (the old intake
        // waits for each before it starts the next).
        for data in pictures.reversed() { gated.release(data) }
        await h.view.attachmentsReady()
        let order = h.view.transcript.draftAttachments.map(\.ref.hash)
        let pasted = pictures.compactMap { gated.hashes[$0] }
        #expect(pasted.count == pictures.count)
        #expect(order == pasted, "the box holds the pictures out of the paste's order")
    }

    /// Measure: a 10-picture paste through the intake, from the paste to the last picture in the box,
    /// and the main thread's longest gap meanwhile (a 1 ms heartbeat). Prints `PASTE-INTAKE`.
    @Test func aTenPicturePasteIsQuick() async throws {
        let h = try await home()
        defer { h.close() }
        let pictures = try (0..<10).map(Self.screenshot)
        var gaps: [Double] = []
        var beating = true
        // task-owner: the heartbeat; ends when the paste does
        let beat = Task { @MainActor in
            var last = ContinuousClock.now
            while beating {
                try? await Task.sleep(for: .milliseconds(1))  // the heartbeat's own period, the measure itself
                let now = ContinuousClock.now
                gaps.append(Self.ms(now - last))
                last = now
            }
        }
        let start = ContinuousClock.now
        #expect(h.view.handlePaste(Self.board(pictures)))
        await h.view.attachmentsReady()
        let total = Self.ms(ContinuousClock.now - start)
        beating = false
        await beat.value
        let sorted = gaps.sorted()
        print(String(format: "PASTE-INTAKE pictures=10 paste_to_last_ms=%.1f main_gap_p99=%.2f main_gap_max=%.2f",
                     total, sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.99)], sorted.last ?? 0))
        #expect(h.view.transcript.draftAttachments.count == pictures.count)
    }
}

import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// Pasting several pictures in the Chief's message box lags (Lawrence 2026-10-23, msg 11952).
/// TextKit 2 draws the field's pictures itself, so a thumbnail that finished decoding asked the
/// field to lay out its WHOLE text again (`invalidateLayout(for: documentRange)`): with N pictures
/// in the box, each of the N thumbnails rebuilt N picture blocks (pictures pasted together share
/// one paragraph, so even that paragraph alone is all of them). A picture draws its thumbnail when
/// it draws, so an arrival needs no layout at all: only its own rect is drawn again, and loads
/// that finish together are one update.
///
/// The observable: the layout fragments TextKit 2 makes (`NSTextLayoutManagerDelegate` asks for
/// each new one) after a thumbnail arrives. The real view over a real `HomeStore` on the mock
/// owner, in an offscreen window; the pictures go in through the paste's own path
/// (`addDraftAttachment`, after the store prepared them).
///
/// It prints one `PASTE-BENCH` line per picture count: the paste's wall time until every
/// thumbnail shows, and the main-thread time of one thumbnail's arrival with its layout.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct HomeComposerPastePicturesCostTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    /// Counts the layout fragments TextKit 2 makes (each one a paragraph laid out again).
    final class FragmentCounter: NSObject, NSTextLayoutManagerDelegate {
        var made = 0
        func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                               in textElement: NSTextElement) -> NSTextLayoutFragment {
            made += 1
            return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }
    }

    static let conversation = ConversationID("conv_chief")

    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(60)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    }

    @MainActor struct Rig {
        let store: HomeStore
        let window: NSWindow
        let view: MessagesLabHomeView
        let blobs: URL
        var compose: ComposeView { view.controller.demo!.compose }
        var field: FieldTextView { compose.textView.view }
        /// The field's pictures, in the text's order.
        var pictures: [ComposeInlineAttachment] {
            guard let s = field.textStorage else { return [] }
            var out: [ComposeInlineAttachment] = []
            s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { v, _, _ in
                if let a = v as? ComposeInlineAttachment { out.append(a) }
            }
            return out
        }
        func layout() {
            window.contentView?.layoutSubtreeIfNeeded()
            if let tlm = field.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
            field.displayIfNeeded()
            CATransaction.flush()
        }
        func close() {
            view.stop(); window.close(); store.stop()
            try? FileManager.default.removeItem(at: blobs)
        }
    }

    private func rig() async throws -> Rig {
        let blobs = FileManager.default.temporaryDirectory.appendingPathComponent("home-paste-cost-\(UUID().uuidString)", isDirectory: true)
        let options = MockHomeSource.Options(chiefHistory: 8, latency: .zero, replyDelay: .seconds(3600))
        let store = HomeStore(source: MockHomeSource(options: options), blobCacheDirectory: blobs)
        store.start()
        await until { store.me != nil && store.isOnline }
        await store.open(Self.conversation)
        await until { !store.transcript(for: Self.conversation).isEmpty }
        let me = try #require(store.me?.id)
        // On screen (behind other windows), so the field really draws its pictures: TextKit 2 asks
        // a picture for its image only when it draws, and that is what a thumbnail redraws.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = MessagesLabHomeView(store: store, conversation: Self.conversation, me: me, wake: NoWake())
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window.contentView = view
        window.orderBack(nil)
        view.layoutSubtreeIfNeeded()
        view.projection.refresh()
        return Rig(store: store, window: window, view: view, blobs: blobs)
    }

    /// A screenshot-sized PNG (1412 x 1106 px, Lawrence's capture), a different colour per INDEX.
    private static func screenshot(_ index: Int) throws -> Data {
        let w = 1412, h = 1106
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: CGFloat(index % 7) / 7, green: 0.4, blue: CGFloat(index % 3) / 3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 40 + index * 30, y: 80, width: 400, height: 60))
        let image = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        _ = CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// Pastes COUNT pictures, one after the other as a multi-picture paste adds them; returns the
    /// wall time until every thumbnail shows, in ms.
    private func paste(_ count: Int, into r: Rig) async throws -> Double {
        var shots: [LocalAttachment] = []
        for i in 0..<count {
            shots.append(try await r.store.prepareAttachment(data: try Self.screenshot(i), typeIdentifier: UTType.png.identifier))
        }
        let start = ContinuousClock.now
        for shot in shots {
            await r.view.addDraftAttachment(shot)
            r.layout()
        }
        await until { r.pictures.count == count && r.pictures.allSatisfy { $0.thumbnail != nil } }
        r.layout()
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

    /// The field's text container draws each picture once, as TextKit 2 does in the app (it draws
    /// the pictures itself there and places no attachment view, `ComposeInlineRemoveHover`); an
    /// offscreen test window may place the views instead, which redraw on their own.
    private static func drawnByTheField(_ pictures: [ComposeInlineAttachment], in r: Rig) {
        for p in pictures { _ = p.image(forBounds: CGRect(origin: .zero, size: p.pictureSize), textContainer: r.field.textContainer, characterIndex: 0) }
    }

    @Test(arguments: [5, 10])
    func aThumbnailThatArrivesLaysOutOnlyItsOwnPicture(_ count: Int) async throws {
        let r = try await rig()
        defer { r.close() }
        let total = try await paste(count, into: r)
        let pictures = r.pictures
        try #require(pictures.count == count, "the field holds \(r.pictures.count) of \(count) pictures")
        Self.drawnByTheField(pictures, in: r)
        let tlm = try #require(r.field.textLayoutManager)
        let counter = FragmentCounter()
        let previous = tlm.delegate
        tlm.delegate = counter
        defer { tlm.delegate = previous }
        r.layout()
        // Each picture's thumbnail arrives again, as a load that finishes does; the field lays out after each.
        var made: [Int] = []
        var arrival: [Double] = []
        for picture in pictures {
            counter.made = 0
            let image = picture.thumbnail
            let t0 = ContinuousClock.now
            picture.thumbnailArrived(image)
            for _ in 0..<4 { await Task.yield() }
            r.layout()
            arrival.append(Self.ms(ContinuousClock.now - t0))
            made.append(counter.made)
        }
        let sorted = arrival.sorted()
        print(String(format: "PASTE-BENCH pictures=%d paste_ms=%.1f arrival_ms_p50=%.2f arrival_ms_max=%.2f fragments_per_arrival=%@",
                     count, total, sorted[sorted.count / 2], sorted.last ?? 0, made.map(String.init).joined(separator: ",")))
        #expect(made.allSatisfy { $0 == 0 },
                "a thumbnail's arrival laid out \(made.max() ?? 0) paragraphs with \(count) pictures (want none: it only draws): \(made)")
    }

    /// Thumbnails that finish together are one update of the field, not one each.
    @Test func thumbnailsThatArriveTogetherAreOneUpdate() async throws {
        let r = try await rig()
        defer { r.close() }
        _ = try await paste(6, into: r)
        let pictures = r.pictures
        try #require(pictures.count == 6)
        Self.drawnByTheField(pictures, in: r)
        let tlm = try #require(r.field.textLayoutManager)
        let counter = FragmentCounter()
        let previous = tlm.delegate
        tlm.delegate = counter
        defer { tlm.delegate = previous }
        r.layout()
        counter.made = 0
        let before = r.field.inlineRedrawUpdates
        for picture in pictures { picture.thumbnailArrived(picture.thumbnail) }
        for _ in 0..<4 { await Task.yield() }
        r.layout()
        #expect(counter.made == 0, "six arrivals together laid out \(counter.made) paragraphs (want none)")
        #expect(r.field.inlineRedrawUpdates - before == 1, "six arrivals together were \(r.field.inlineRedrawUpdates - before) updates (want one)")
    }
}

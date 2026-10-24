import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// Where a multi-picture paste into the Chief's message box spends its time (Lawrence 2026-10-23,
/// msg 11952: pasting several images lags). Measure only, no pass bar: fleet 2026-10-24 (aws-m4pro-1)
/// at 10 pictures, the field's whole-text rebuild per attach was 0.5 ms (not the lag), no main-thread
/// stall passed 8.3 ms (worst gap 4.5 ms), and each picture's store prepare (about 20 ms) and bubble
/// picture (about 11 ms) ran off the main actor one picture after the other. The real view over a real `HomeStore` on the mock owner, in a window
/// behind the others; the pictures go in through the paste's own path (`addDraftAttachment`, after
/// the store prepared them), one at a time as a multi-picture paste adds them.
///
/// Prints `PASTE-REBUILD` lines: each attach's main-thread time (the attach and the layout after
/// it), the text characters the field's storage replaced per attach, and the parts of one attach
/// at 10 pictures, timed on their own.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct HomeComposerPasteRebuildCostTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    /// The characters each edit of the field's storage replaced (its edited range's length).
    final class StorageEdits {
        var lengths: [Int] = []
        private var token: (any NSObjectProtocol)?
        init(_ storage: NSTextStorage) {
            token = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage,
                                                           queue: nil) { [weak self] note in
                guard let s = note.object as? NSTextStorage, s.editedMask.contains(.editedCharacters) else { return }
                self?.lengths.append(s.editedRange.length)
            }
        }
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
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
        let blobs = FileManager.default.temporaryDirectory.appendingPathComponent("home-paste-rebuild-\(UUID().uuidString)", isDirectory: true)
        let options = MockHomeSource.Options(chiefHistory: 8, latency: .zero, replyDelay: .seconds(3600))
        let store = HomeStore(source: MockHomeSource(options: options), blobCacheDirectory: blobs)
        store.start()
        await until { store.me != nil && store.isOnline }
        await store.open(Self.conversation)
        await until { !store.transcript(for: Self.conversation).isEmpty }
        let me = try #require(store.me?.id)
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

    /// A screenshot-sized PNG (1412 x 1106 px), a different colour per INDEX.
    private static func screenshot(_ index: Int) throws -> Data {
        let w = 1412, h = 1106
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: CGFloat(index % 7) / 7, green: 0.4, blue: CGFloat(index % 3) / 3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let image = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        _ = CGImageDestinationFinalize(dest)
        return out as Data
    }

    private static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

    private static func time(_ body: () -> Void) -> Double {
        let t = ContinuousClock.now
        body()
        return ms(ContinuousClock.now - t)
    }

    private static func row(_ xs: [Double]) -> String { xs.map { String(format: "%.2f", $0) }.joined(separator: ",") }

    /// Each attach's time, the characters it replaced in the field's text (the whole text: the field
    /// builds it again), and the parts of one update at 10 pictures. Prints `PASTE-REBUILD`.
    @Test func whatEachPastedPictureCosts() async throws {
        let r = try await rig()
        defer { r.close() }
        let count = 10
        var shots: [LocalAttachment] = []
        for i in 0..<count {
            shots.append(try await r.store.prepareAttachment(data: try Self.screenshot(i), typeIdentifier: UTType.png.identifier))
        }
        let storage = try #require(r.field.textStorage)
        r.window.makeFirstResponder(r.field)
        r.layout()
        let edits = StorageEdits(storage)
        var perAttach: [Double] = [], replaced: [Int] = []
        for shot in shots {
            let before = edits.lengths.count
            let t = ContinuousClock.now
            await r.view.addDraftAttachment(shot)
            r.layout()
            perAttach.append(Self.ms(ContinuousClock.now - t))
            replaced.append(edits.lengths.dropFirst(before).reduce(0, +))
        }
        // The parts of one more update at 10 pictures, each on its own.
        let d = try #require(r.view.controller.store?.state.ui.draft)
        var cache = r.compose.inlineAttachments
        let build = Self.time { _ = ComposeInlineText.build(d.text, attachments: d.attachments, cache: &cache, scale: 2, onRemove: { _ in }) }
        let built = ComposeInlineText.build(d.text, attachments: d.attachments, cache: &cache, scale: 2, onRemove: { _ in })
        let set = Self.time { storage.setAttributedString(built) }
        let relayout = Self.time { r.layout() }
        let extra = Self.time { _ = ComposeInlineText.extraHeight(storage, width: 500) }
        print("PASTE-REBUILD attach_ms=\(Self.row(perAttach)) replaced_chars=\(replaced.map(String.init).joined(separator: ","))")
        print(String(format: "PASTE-REBUILD parts_at_10 build_ms=%.2f set_ms=%.2f relayout_ms=%.2f extra_height_ms=%.2f", build, set, relayout, extra))
        #expect(replaced.count == count)
    }

    /// Where a 10-picture paste's time goes, and how long the main thread stalls while it runs (a
    /// 1 ms heartbeat on the main actor records its gaps). Measure only: prints `PASTE-STAGES`.
    @Test func whereAPastesTimeGoes() async throws {
        let r = try await rig()
        defer { r.close() }
        r.window.makeFirstResponder(r.field)
        r.layout()
        // The pictures' bytes before the clock starts: making a PNG is the test's work, not the paste's.
        let datas = try (0..<10).map { try Self.screenshot($0) }
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
        var storeMs: [Double] = [], mediaMs: [Double] = [], attachMs: [Double] = []
        let start = ContinuousClock.now
        for data in datas {
            var t = ContinuousClock.now
            let shot = try await r.store.prepareAttachment(data: data, typeIdentifier: UTType.png.identifier)
            storeMs.append(Self.ms(ContinuousClock.now - t))
            t = ContinuousClock.now
            await r.view.projection.media.prepare(shot)
            mediaMs.append(Self.ms(ContinuousClock.now - t))
            t = ContinuousClock.now
            await r.view.addDraftAttachment(shot)
            r.layout()
            attachMs.append(Self.ms(ContinuousClock.now - t))
        }
        await until { r.compose.inlineAttachments.values.allSatisfy { $0.thumbnail != nil } }
        r.layout()
        let total = Self.ms(ContinuousClock.now - start)
        beating = false
        await beat.value
        let sorted = gaps.sorted()
        let stalls = gaps.filter { $0 > 8.3 }
        print(String(format: "PASTE-STAGES total_ms=%.1f main_gap_p50=%.2f main_gap_p99=%.2f main_gap_max=%.2f stalls_over_8ms=%d stall_ms_sum=%.1f",
                     total, sorted[sorted.count / 2], sorted[Int(Double(sorted.count - 1) * 0.99)], sorted.last ?? 0,
                     stalls.count, stalls.reduce(0, +)))
        print("PASTE-STAGES store_prepare_ms=\(Self.row(storeMs))")
        print("PASTE-STAGES media_prepare_ms=\(Self.row(mediaMs))")
        print("PASTE-STAGES attach_and_layout_ms=\(Self.row(attachMs))")
    }
}

import AppKit
@testable import CmuxHomeCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// Dragging pictures onto Home's message box while the Chief's reply streams
/// stays smooth (Lawrence 2026-10-19: "dragging images in while text is
/// streaming is extremely laggy"). The real view (`MessagesLabHomeView`) over
/// a real `HomeStore` on the mock owner, in an offscreen window: each frame
/// gets one streamed token (`HomeProjection.refresh`, as the store's
/// observation runs it), a layout pass, and one drag-over event on the field.
///
/// AppKit's drag server waits for the destination's answer to each drag-over
/// event, so the drag image moves only as fast as the main thread answers.
/// The rules:
/// - a drag-over event reads the drag's pasteboard at most once per drag
///   (its answer depends only on the pasteboard, not on the stream);
/// - a streamed token does not move or redraw the field (the drop target);
/// - token plus drag-over stays inside one 60 Hz frame (16 ms, p95).
///
/// `DRAGLAG` lines in the log carry the numbers (BASELINE.md).
@MainActor @Suite(.serialized) struct DragWhileStreamingTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    /// One drag session over the field: a fixed pasteboard and sequence number.
    @MainActor final class Drag: NSObject, NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        let draggingSequenceNumber: Int
        weak var window: NSWindow?
        var location: NSPoint
        init(_ pasteboard: NSPasteboard, sequence: Int, window: NSWindow, at location: NSPoint) {
            draggingPasteboard = pasteboard
            draggingSequenceNumber = sequence
            self.window = window
            self.location = location
        }
        var draggingDestinationWindow: NSWindow? { window }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggingLocation: NSPoint { location }
        var draggedImageLocation: NSPoint { location }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    static let conversation = ConversationID("conv_chief")

    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    /// A camera-sized PNG on disk (the kind of picture a person drags in).
    private func png(_ name: String, in dir: URL) throws -> URL {
        let w = 3024, h = 2016
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let seed = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        for i in 0..<24 {
            ctx.setFillColor(CGColor(red: CGFloat((i + seed) % 5) / 5, green: CGFloat(i % 7) / 7, blue: CGFloat(i % 3) / 3, alpha: 1))
            ctx.fill(CGRect(x: i * 120, y: (i * 77) % h, width: 600, height: 400))
        }
        let image = try #require(ctx.makeImage())
        let url = dir.appendingPathComponent(name)
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    private static func ms(_ t0: CFTimeInterval) -> Double { (CACurrentMediaTime() - t0) * 1000 }

    private static func p(_ xs: [Double], _ q: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * q).rounded()))]
    }

    private static func line(_ name: String, _ xs: [Double]) -> String {
        String(format: "%@ p50 %.2f p95 %.2f max %.2f ms", name, p(xs, 0.5), p(xs, 0.95), xs.max() ?? 0)
    }

    @Test(arguments: [0, 3])
    func dragOverTheFieldWhileAReplyStreams(draftPictures: Int) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("drag-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: dir.appendingPathComponent("blobs"))
        store.start()
        defer { store.stop() }
        await until { store.me != nil && store.isOnline }
        await store.open(Self.conversation)
        await until { !store.transcript(for: Self.conversation).isEmpty }
        let me = try #require(store.me?.id)
        let chief = try #require(store.transcript(for: Self.conversation).first { $0.author != me }?.author)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = MessagesLabHomeView(store: store, conversation: Self.conversation, me: me, wake: NoWake(), replies: .streaming)
        defer { view.stop() }
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let projection = view.projection
        // The display frame: work the view schedules for the next frame (one streamed-text commit per
        // frame, HomeStreamPacer) runs at the start of each loop step (an offscreen window's link may not fire).
        var pending: [() -> Void] = []
        view.controller.nextFrame = { pending.append($0) }
        func frameStart() {
            while !pending.isEmpty {
                let w = pending
                pending.removeAll()
                for f in w { f() }
            }
        }
        let field = try #require(view.controller.demo?.compose.textView.view)

        // The host's type check (Home's intake reads the drag's types and file URLs, a round trip to
        // the pasteboard server per read), counted. A ci-step mini may have no pasteboard server, so
        // the answer does not depend on what the read returns.
        var intakeReads = 0
        view.acceptsAttachmentDrag = { board in
            intakeReads += 1
            _ = board.readObjects(forClasses: [NSURL.self], options: nil)
            return true
        }

        // Pictures already in the field (a drop a moment ago).
        for i in 0..<draftPictures {
            let prepared = try await store.prepareAttachment(fileURL: try png("draft-\(i).png", in: dir))
            await view.addDraftAttachment(prepared)
        }
        #expect(view.draftAttachments.count == draftPictures)
        view.layoutSubtreeIfNeeded()

        // The drag: three pictures from Finder.
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        let dragged = try (0..<3).map { try png("drag-\($0).png", in: dir) }
        board.writeObjects(dragged.map { $0 as NSURL })
        let fieldCenter = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        let drag = Drag(board, sequence: 41, window: window, at: fieldCenter)
        #expect(field.draggingEntered(drag) == .copy)

        // No stream: the pointer sweeps between the transcript and the field, 30 events on each, as
        // AppKit calls them: draggingEntered on the field at each crossing, draggingUpdated after it.
        // Over the transcript the drag belongs to the host's view around this one (Home's drop target,
        // HomeNativeTranscriptView, which reads the drag once per drag too): the field gets its exit.
        var idleDragOver: [Double] = []
        for i in 0..<240 {
            let onField = i % 60 >= 30
            drag.location = onField ? NSPoint(x: fieldCenter.x + CGFloat(i % 30) - 15, y: fieldCenter.y) : fieldCenter
            let d0 = CACurrentMediaTime()
            let op: NSDragOperation
            switch (onField, i % 30) {
            case (false, 0): field.draggingExited(drag); op = .copy // the surrounding drop target answers
            case (false, _): op = .copy
            case (true, 0): op = field.draggingEntered(drag)
            case (true, _): op = field.draggingUpdated(drag)
            }
            idleDragOver.append(Self.ms(d0))
            #expect(op == .copy)
        }
        let idleReads = intakeReads
        drag.location = fieldCenter
        #expect(field.draggingEntered(drag) == .copy)
        intakeReads = 0

        // The reply streams, one token per frame, while the pointer moves over the field.
        let turn = IdempotencyKey("turn_drag_stream")
        var draft = HomeTurnDraft(participant: chief, turn: turn)
        let fieldFrame0 = field.convert(field.bounds, to: nil)
        var fieldMoves = 0
        var token: [Double] = [], layout: [Double] = [], dragOver: [Double] = [], frame: [Double] = []
        var text = ""
        var transcriptMs: [Double] = [], commitMs: [Double] = [], stepMs: [Double] = [], attachMs: [Double] = []
        var commitPhases: [String: Double] = [:]
        MessagesWindowView.commitLog = []
        defer { MessagesWindowView.commitLog = nil }
        let words = "Here is the plan for the build: rebase on the branch, run the suites on the fleet, then push and report the shas. "
            .split(separator: " ")
        for i in 0..<240 {
            text += (text.isEmpty ? "" : " ") + words[i % words.count]
            if i % 37 == 36 { text += "\n\n" }
            draft.segments[0] = text
            draft.lastSeq = UInt64(i + 1)
            let t0 = CACurrentMediaTime()
            _ = store.transcript(for: Self.conversation)
            transcriptMs.append(Self.ms(t0))
            var copy = projection.core
            let s0 = CACurrentMediaTime()
            _ = copy.step(items: projection.shown, summary: projection.shownSummary)
            stepMs.append(Self.ms(s0))
            let a0 = CACurrentMediaTime()
            projection.refreshAttachments()
            attachMs.append(Self.ms(a0))
            frameStart()
            MessagesWindowView.commitLog = []
            let f0 = CACurrentMediaTime()
            store.showDraft(draft, turn: draft.turn, author: draft.participant, in: Self.conversation)
            projection.refresh()
            token.append(Self.ms(f0))
            var c = 0.0
            for entry in MessagesWindowView.commitLog ?? [] {
                let f = entry.split(separator: " ")
                if f.count > 1, let v = Double(f[1]) { c += v; commitPhases["commit." + f[0], default: 0] += v }
                // the phases dictionary text: "[name: ms, ...]"
                if let open = entry.firstIndex(of: "[") {
                    for kv in entry[entry.index(after: open)...].split(separator: ",") {
                        let parts = kv.split(separator: ":")
                        guard parts.count == 2 else { continue }
                        let k = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: " \"[]"))
                        let v = Double(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " ]"))) ?? 0
                        commitPhases["phase." + k, default: 0] += v
                    }
                }
            }
            commitMs.append(c)
            let l0 = CACurrentMediaTime()
            window.contentView?.layoutSubtreeIfNeeded()
            CATransaction.flush()
            layout.append(Self.ms(l0))
            drag.location = NSPoint(x: fieldCenter.x + CGFloat(i % 40) - 20, y: fieldCenter.y + CGFloat(i % 7) - 3)
            let d0 = CACurrentMediaTime()
            let op = field.draggingUpdated(drag)
            dragOver.append(Self.ms(d0))
            frame.append(Self.ms(f0))
            #expect(op == .copy)
            if field.convert(field.bounds, to: nil) != fieldFrame0 { fieldMoves += 1 }
            // The store's own observation refresh (a no-op: nothing changed since).
            await Task.yield()
        }

        let label = "pictures=\(draftPictures) rows=\(projection.shown.count)"
        print("DRAGLAG \(label) \(Self.line("token", token))")
        print("DRAGLAG \(label) \(Self.line("transcript(for:)", transcriptMs))")
        print("DRAGLAG \(label) \(Self.line("commits", commitMs))")
        print("DRAGLAG \(label) \(Self.line("unchanged-items diff (core.step)", stepMs))")
        print("DRAGLAG \(label) \(Self.line("refreshAttachments", attachMs))")
        for b in stride(from: 0, to: token.count, by: 40) {
            print("DRAGLAG \(label) tokens \(b)..<\(b + 40) \(Self.line("token", Array(token[b..<min(token.count, b + 40)])))")
        }
        for (k, v) in commitPhases.sorted(by: { $0.value > $1.value }).prefix(16) {
            print(String(format: "DRAGLAG %@ total %@ %.1f ms", label, k, v))
        }
        print("DRAGLAG \(label) no-stream \(Self.line("dragOver", idleDragOver)) intakeReads \(idleReads) per 240")
        print("DRAGLAG \(label) \(Self.line("layout", layout))")
        print("DRAGLAG \(label) \(Self.line("dragOver", dragOver))")
        print("DRAGLAG \(label) \(Self.line("frame", frame))")
        print("DRAGLAG \(label) intakeReads \(intakeReads) per 240 drag-over events, fieldMoves \(fieldMoves) maxCommit \(String(format: "%.2f", MessagesWindowView.maxCommitMs)) ms")

        #expect(intakeReads <= 1, "a drag-over event reads the drag's pasteboard at most once per drag (\(intakeReads) reads)")
        #expect(fieldMoves == 0, "a streamed token moves the field \(fieldMoves) times")
        #expect(Self.p(dragOver, 0.95) < 1, "drag-over p95 \(Self.p(dragOver, 0.95)) ms")
        #expect(Self.p(idleDragOver, 0.95) < 1, "drag-over with no stream p95 \(Self.p(idleDragOver, 0.95)) ms")
        // Crossing between the transcript and the field re-asks once per crossing (8 crossings), never per event.
        #expect(idleReads <= 10, "a sweep with no stream read the drag's pasteboard \(idleReads) times in 240 events")
        // A token changes only the stream: diffing the unchanged snapshot maps no row (it cost 3.5 ms p50
        // at 60 rows on an M4 Pro mini, every token, before ProjectionCore.step returned early).
        #expect(Self.p(stepMs, 0.5) < 0.5, "an unchanged snapshot's diff p50 \(Self.p(stepMs, 0.5)) ms")
        #expect(Self.p(frame, 0.95) < 16, "token + drag-over p95 \(Self.p(frame, 0.95)) ms")
    }
}

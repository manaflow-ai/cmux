import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// A divider drag (or live window resize) while the Chief's reply streams: every display frame
/// shows the rows at the transcript's current width (a102's lead on the clipped blue bubbles).
///
/// Each token changes the streaming bubble, and the width pass's fast path (re-measuring the last
/// width's rows, `RowBuilder.rewidth`) needed the streams unchanged: so in a drag every pass
/// derived the rows of every loaded message again. That pass took more than the frame's width
/// budget, so the frame's second width change waited for the next frame, and the frame showed
/// the new width with the rows of the old one (bubbles cut at the transcript's edge).
///
/// The test supplies the display frames (an offscreen window has no display link: the per-frame
/// width work runs only at `frameStart`). Each frame: its start, a token, two width changes (a
/// drag delivers 2 mouse events per 60 Hz frame), a token, layout and a Core Animation flush.
@MainActor @Suite(.serialized) struct HomeResizeWhileStreamingTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let conversation = ConversationID("conv_chief")

    /// A Chief-shaped Markdown reply as tokens (headings, bullets, a code block, a table).
    static func replyTokens(count: Int) -> [String] {
        var tokens: [String] = []
        var section = 0
        func words(_ s: String) { for w in s.split(separator: " ", omittingEmptySubsequences: false) { tokens.append(String(w) + " ") } }
        while tokens.count < count {
            section += 1
            tokens.append("## Step \(section): rebuild the branch\n\n")
            words("Here is the plan for step \(section). Rebase on **origin/feat-cmux-next**, run the suites on the fleet, then push and report the `sha` of each commit.")
            tokens.append("\n\n")
            for i in 1...4 { tokens.append("- "); words("item \(i): check `cmux-ci wait` and read the *log* for step \(section)"); tokens.append("\n") }
            tokens.append("\n```swift\n")
            for i in 0..<12 { tokens.append("let value\(i) = try await fleet.run(step: \(section), shard: \(i)) // keep going\n") }
            tokens.append("```\n\n")
            tokens.append("| Suite | Result | Time |\n|---|---|---|\n")
            for i in 0..<5 { tokens.append("| Suite\(i) "); tokens.append("| passed "); tokens.append("| \(i * 3 + section) s |\n") }
            tokens.append("\n")
        }
        return Array(tokens.prefix(count))
    }

    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    @Test func everyFrameOfADragWhileStreamingShowsRowsAtTheCurrentWidth() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("home-resize-stream-\(UUID().uuidString)")
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = MessagesLabHomeView(store: store, conversation: Self.conversation, me: me, wake: NoWake(), replies: .streaming)
        defer { view.stop() }
        view.frame = NSRect(x: 0, y: 0, width: 1200, height: 900)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let demo = try #require(view.controller.demo)
        var pending: [() -> Void] = []
        view.controller.nextFrame = { pending.append($0) }
        func frameStart() {
            let w = pending
            pending.removeAll()
            for f in w { f() }
        }
        func flush() {
            window.contentView?.layoutSubtreeIfNeeded()
            CATransaction.flush()
        }

        let tokens = Self.replyTokens(count: 1600)
        var draft = HomeTurnDraft(participant: chief, turn: IdempotencyKey("turn_resize_stream"))
        var text = "", i = 0
        func token() {
            guard i < tokens.count else { return }
            text += tokens[i]
            i += 1
            draft.segments[0] = text
            draft.lastSeq = UInt64(i)
            store.showDraft(draft, turn: draft.turn, author: draft.participant, in: Self.conversation)
            view.projection.refresh()
        }
        // The reply has started (the stream bubble shows) before the drag.
        for _ in 0..<40 { frameStart(); token(); flush() }

        // The drag: 1200 -> 480 -> 1200 pt and back, 6 pt per mouse event.
        var width: CGFloat = 1200, step: CGFloat = -6
        var changeMs: [Double] = []
        func drag() {
            let c0 = CACurrentMediaTime()
            defer { changeMs.append((CACurrentMediaTime() - c0) * 1000) }
            width += step
            if width <= 480 || width >= 1200 { step = -step }
            view.setFrameSize(NSSize(width: width, height: 900))
            view.layoutSubtreeIfNeeded()
        }
        var staleFrames: [(frame: Int, width: CGFloat, rows: Set<CGFloat>)] = []
        var frameMs: [Double] = []
        var frame = 0
        let passes0 = MessagesWindowView.widthPasses, deferred0 = MessagesWindowView.widthPassesDeferred
        let full0 = MessagesWindowView.widthRowsDerived
        while i < tokens.count {
            let t0 = CACurrentMediaTime()
            frameStart()
            token()
            drag()
            drag()
            token()
            flush()
            frameMs.append((CACurrentMediaTime() - t0) * 1000)
            // What this frame shows: the rows' width against the transcript's.
            let rowWidths = Set(demo.model.rows.filter { !$0.ghost }.map(\.spec.width))
            if rowWidths != [demo.bounds.width] { staleFrames.append((frame, demo.bounds.width, rowWidths)) }
            frame += 1
        }
        let sorted = frameMs.sorted()
        func p(_ q: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))] }
        print(String(format: "HOMERESIZE frames %d p50 %.2f p95 %.2f p99 %.2f max %.2f ms widthPasses %d deferred %d stale %d bytes %d",
                     frameMs.count, p(0.5), p(0.95), p(0.99), sorted.last ?? 0,
                     MessagesWindowView.widthPasses - passes0, MessagesWindowView.widthPassesDeferred - deferred0, staleFrames.count, text.utf8.count))
        let changes = changeMs.sorted()
        func q(_ x: Double) -> Double { changes.isEmpty ? 0 : changes[min(changes.count - 1, Int((Double(changes.count - 1) * x).rounded()))] }
        print(String(format: "HOMERESIZE width change (pass, layout) n %d p50 %.2f p95 %.2f max %.2f ms", changes.count, q(0.5), q(0.95), changes.last ?? 0))
        print("HOMERESIZE full row derivations \(MessagesWindowView.widthRowsDerived - full0)")
        for s in staleFrames.prefix(5) { print("HOMERESIZE stale frame \(s.frame) width \(s.width) rows \(s.rows.sorted())") }
        #expect(view.controller.store?.state.ui.streams.isEmpty == false, "the reply streams through the drag")
        #expect(staleFrames.isEmpty, "\(staleFrames.count) of \(frameMs.count) frames showed rows at a width other than the transcript's")
    }
}

import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// Press and hold on a Home bubble opens the tapback picker over a dimmed pane, and the
/// pressed bubble stays bright, upright and in its place (Lawrence 2026-10-20: "I held a
/// message, left-clicked for a long time, and then it became weird and upside down"). The
/// bubble used to be a bitmap copy of its row laid over the dim; the copy's orientation
/// depended on the flips of the views above it, and in a cmux-next pane it drew upside
/// down over its neighbours. These tests open the picker on a real `ChatController` in an
/// offscreen window, inside a pane-like container, and compare the rendered pane before and
/// after: inside the pressed bubble every pixel must be unchanged.
@MainActor @Suite(.serialized) struct TapbackPressedBubbleTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    final class Flipped: NSView { override var isFlipped: Bool { true } }

    static let me = ParticipantID("user_me")
    static let them = ParticipantID("agent_chief")

    /// A loaded conversation in a window. `flippedContainer`: the host sits in a flipped container
    /// view with an offset, as a cmux-next pane holds it (not the window's content view).
    private func pane(flippedContainer: Bool) -> (NSWindow, ChatController) {
        let people = [CmuxHomeCore.Participant(id: Self.me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: Self.them, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = (1...6).map { i in
            TranscriptItem(key: IdempotencyKey("k\(i)"), seq: Seq(i), author: i % 2 == 0 ? Self.me : Self.them,
                           parts: [.text("Message \(i): Quick brown fox jumps over the lazy dog, then naps")],
                           createdAt: base.addingTimeInterval(Double(i)), delivery: .committed, messageID: MessageID("msg_\(i)"))
        }
        let summary = ConversationSummary(id: ConversationID("conv_tap"), title: "Chief", participants: people, lastSeq: 6,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: Self.me)
        let (conv, w) = core.install(ConversationID("conv_tap"), items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 760), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 600, height: 700)), wake: NoWake())
        if flippedContainer {
            let container = Flipped(frame: NSRect(x: 0, y: 0, width: 640, height: 760))
            container.wantsLayer = true
            window.contentView = container
            controller.host.frame = NSRect(x: 20, y: 40, width: 600, height: 700)
            container.addSubview(controller.host)
        } else {
            window.contentView = controller.host
        }
        controller.install(conv, windowStart: w.start, total: w.total)
        settle(controller)
        return (window, controller)
    }

    private func settle(_ c: ChatController) {
        c.host.layoutSubtreeIfNeeded()
        c.demo?.layoutIfNeeded()
        c.demo?.collection.layoutIfNeeded()
        CATransaction.flush()
    }

    /// The host's whole layer tree drawn into an RGBA bitmap at 2x.
    private func render(_ c: ChatController) throws -> (data: [UInt8], width: Int, height: Int) {
        let layer = try #require(c.host.layer)
        let w = Int(c.host.bounds.width * 2), h = Int(c.host.bounds.height * 2)
        var data = [UInt8](repeating: 0, count: w * h * 4)
        try data.withUnsafeMutableBytes { buf in
            // SAFETY: buf is the array's storage, w * h * 4 bytes (its count), lent for this closure; the context writes
            // w * 4 bytes a row for h rows inside it, and is not drawn into after the closure.
            let ctx = try #require(unsafe CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.scaleBy(x: 2, y: 2)
            layer.render(in: ctx)
        }
        return (data, w, h)
    }

    /// The pixel rows of `r` (host points) in the bitmap: the bitmap's rows run up or down
    /// depending on how the host's layer is flipped, so both readings are returned.
    private func pixelRects(_ r: CGRect, height: CGFloat) -> [CGRect] {
        let down = CGRect(x: r.minX * 2, y: r.minY * 2, width: r.width * 2, height: r.height * 2).integral
        let up = CGRect(x: r.minX * 2, y: (height - r.maxY) * 2, width: r.width * 2, height: r.height * 2).integral
        return [down, up]
    }

    /// The share of pixels in `rect` (bitmap pixels, rows from the buffer's start) that are the
    /// same in both renders, outside `excluded`; `shift`: the second render read that many rows on.
    private func unchangedShare(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int, in rect: CGRect, excluding excluded: [CGRect],
                                shift: Int = 0) -> Double {
        var same = 0, total = 0
        for y in max(0, Int(rect.minY))..<min(height, Int(rect.maxY)) {
            for x in max(0, Int(rect.minX))..<min(width, Int(rect.maxX)) {
                let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                if excluded.contains(where: { $0.contains(p) }) { continue }
                let i = (y * width + x) * 4
                let ys = y + shift
                guard ys >= 0, ys < height else { continue }
                let j = (ys * width + x) * 4
                let d = (0..<3).map { abs(Int(a[i + $0]) - Int(b[j + $0])) }.max() ?? 0
                total += 1
                if d <= 3 { same += 1 }
            }
        }
        return total == 0 ? 0 : Double(same) / Double(total)
    }

    private func check(flippedContainer: Bool) throws {
        let (window, c) = pane(flippedContainer: flippedContainer)
        defer { c.closePicker(); window.close() }
        let demo = try #require(c.demo)
        let row = try #require(demo.lastTextRow(mine: false))
        let hit = try #require(demo.hit(CGPoint(x: row.body.midX, y: row.body.midY)))
        let before = try render(c)

        c.showPicker(for: hit)
        settle(c)
        #expect(c.picker != nil)
        let after = try render(c)

        // The picker, its emoji button and anything else laid over the pane on purpose cover
        // part of the bubble; only the dim (and a copy of the bubble) may lie under the rest.
        let overlays = c.host.subviews.filter { $0 is TapbackPickerView || $0 is EmojiBubbleButton }.map(\.frame)
        let H = c.host.bounds.height
        // The bubble's inside, clear of its soft edge.
        let inside = hit.body.insetBy(dx: 6, dy: 4)
        // The transcript may settle by a point between the two renders (the whole pane moves, dimmed
        // rows too), so the bubble may be up to 2 pt (4 px) off; a flipped or moved copy matches at no shift.
        let shares = [0, 1].map { reading in
            (-4...4).map { shift in
                unchangedShare(before.data, after.data, width: before.width, height: before.height,
                               in: pixelRects(inside, height: H)[reading],
                               excluding: overlays.map { pixelRects($0.insetBy(dx: -2, dy: -2), height: H)[reading] }, shift: shift)
            }.max() ?? 0
        }
        // Upright, in place and the same size: the bubble's pixels are what they were.
        #expect((shares.max() ?? 0) > 0.99, "the pressed bubble changed under the picker (unchanged share \(shares)): flipped, moved or dimmed")
        // The rest of the pane is dimmed (a strip at the top edge; its mirror is at the bottom edge, dimmed too).
        let away = CGRect(x: c.host.bounds.midX - 15, y: 2, width: 30, height: 14)
        let dimmed = [0, 1].map { reading in
            unchangedShare(before.data, after.data, width: before.width, height: before.height,
                           in: pixelRects(away, height: H)[reading], excluding: [])
        }
        #expect(dimmed.allSatisfy { $0 < 0.5 }, "the pane is not dimmed under the picker (unchanged share \(dimmed))")
    }

    @Test func thePressedBubbleStaysUprightInTheWindowsContentView() throws {
        try check(flippedContainer: false)
    }

    @Test func thePressedBubbleStaysUprightInAPane() throws {
        try check(flippedContainer: true)
    }
}

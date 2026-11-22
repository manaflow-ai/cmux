import AppKit
import Testing
@testable import MessagesLabHome

/// Crash program (index_subscript / int_conversion): layout state from an older window
/// (a message range, a part index) and non-finite geometry refuse or clamp instead of
/// trapping. Seeded, so a failure replays.
@MainActor @Suite struct RenderIndexFuzzTests {
    static func message(_ i: Int, deleted: Bool = false) -> Message {
        var m = Message(id: "m\(i)", senderId: i % 3 == 0 ? "me" : "them", sentAt: Instant.format(Date(timeIntervalSince1970: 1_790_000_000 + Double(i) * 40)),
                        parts: [.text("message \(i)", runs: [])], replyTo: nil, status: nil, edits: nil, retractedAt: nil, reactions: [])
        if deleted { m.deletedAt = m.sentAt }
        return m
    }

    @Test func aRowRangeFromALongerWindowDoesNotTrap() {
        let messages = (0..<6).map { Self.message($0, deleted: $0 == 2) }
        let store = Store(conversation: Conversation(id: "c", title: "t", participants: [], messages: messages), baseDate: Date())
        let now = Date(timeIntervalSince1970: 1_790_001_000)
        for range in [0..<6, 3..<40, 10..<20, 0..<0] {
            let rows = RowBuilder.rows(store.state, messages: messages, now: now, range: range, width: 600)
            #expect(rows.allSatisfy { $0.width == 600 })
        }
    }

    @Test func aStalePartIndexMeasuresNothing() {
        let m = Self.message(1)
        #expect(MeasureCache.shared.size(m, 5, width: 400).size == .zero)
        #expect(MeasureCache.shared.size(m, -1, width: 400).size == .zero)
    }

    @Test func nonFiniteGeometryAndTimesDoNotTrap() throws {
        let layout = TextLayout.make("one\ntwo three four five", runs: [], maxWidth: 80)
        for y in [CGFloat.nan, .infinity, -.infinity, 1e300] { #expect(layout.link(at: CGPoint(x: 4, y: y)) == nil) }
        for s in [Double.nan, .infinity, -.infinity, 1e300, 61] { _ = Format.duration(s) }
        _ = Format.bytes(Int.max)
        for y in [CGFloat.nan, .infinity, -1e9, 0, 1e9] { _ = MorphBubble.blue(atWindowY: y) }
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = try #require(rep.cgImage)
        _ = MorphBubble.boxBlur(image, radiusPx: -3)
    }
}

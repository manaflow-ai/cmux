@testable import CmuxNextHome
import CoreGraphics
import Foundation
import Testing

struct MeasureAndMotionTests {
    @Test func measureKeyIsRowPartVersionAndQuantizedWidth() {
        let g = TranscriptGeometry.make(width: 600, fontSize: 13, captionSize: 11, space: (2, 4, 6, 8, 10, 12))
        let message = HomeFixture.messages(7...7)[0]
        let key = Measurer.key(message, part: 0, geometry: g)
        #expect(key == Measurer.key(message, part: 0, geometry: g))
        #expect(key != Measurer.key(message, part: 1, geometry: g))
        var edited = message
        edited.editedAt = HomeFixture.base.addingTimeInterval(99)
        #expect(Measurer.key(edited, part: 0, geometry: g) != key)
        // text width is quantized to 8 pt: a 2 pt resize keeps every cached size
        let nudged = TranscriptGeometry.make(width: g.width + 2, fontSize: 13, captionSize: 11, space: (2, 4, 6, 8, 10, 12))
        #expect(nudged.maxTextWidth == g.maxTextWidth)
        #expect(Measurer.key(message, part: 0, geometry: nudged) == key)
        // a pending message keeps its key when it is confirmed (row key = client id)
        var confirmed = HomeFixture.pending("cm_9", at: 0)
        let pendingKey = Measurer.key(confirmed, part: 0, geometry: g)
        confirmed.seq = 10
        confirmed.id = "msg_10"
        #expect(Measurer.key(confirmed, part: 0, geometry: g) == pendingKey)
    }

    @Test func measurerCachesAndEstimatesAreReplaced() {
        let measurer = Measurer()
        let g = HomeFixture.geometry
        let messages = HomeFixture.messages(1...20)
        measurer.measure(messages, geometry: g)
        #expect(measurer.count == 20)
        let measured = measurer.measuredCount
        measurer.measure(messages, geometry: g)
        #expect(measurer.measuredCount == measured)
        let long = HomePart.text(String(repeating: "wrap me ", count: 80))
        let size = Measurer.measure(long, geometry: g)
        #expect(size.width <= g.maxBubbleWidth)
        #expect(size.height > g.lineHeight * 3)
        #expect(size.height.truncatingRemainder(dividingBy: g.lineHeight) == (2 * g.insetY).truncatingRemainder(dividingBy: g.lineHeight))
    }

    @Test func springClosedFormStartsAtZeroAndSettles() {
        for timing in [TranscriptTiming.sendScroll, .flightTop, .flightBottom, .flightRight, .flightLeftA, .flightLeftB] {
            #expect(timing.progress(0) == 0)
            #expect(abs(timing.progress(timing.settle) - 1) < 0.002)
        }
        #expect(TranscriptTiming.received.progress(TranscriptTiming.received.settle) == 1)
        #expect(TranscriptTiming.hold(duration: 0.6).progress(0.3) == 0)
    }

    @Test func additiveComponentsSumAndEnd() {
        let a = MotionComponent(id: 1, start: 0, delta: 100, timing: .sendScroll)
        let b = MotionComponent(id: 2, start: 0.1, delta: -30, timing: .received)
        let both = [a, b]
        #expect(both.offset(at: 0) == CGFloat(70))
        #expect(abs(both.offset(at: both.end + 0.01)) < 0.2)
        #expect(both.reach == 130)
        #expect(both.end == max(a.end, b.end))
    }
}

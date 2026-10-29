import AppKit
import CmuxNextInput
import CmuxNextInputCore
import CoreGraphics
import Testing

/// An AppKit scroll's place in its gesture reaches its record: momentum before the
/// gesture phase, and the momentum's end as a phase of its own, which closes the pending-input
/// check's scroll sequence (`SessionInputPending.ScrollLatching`); folded into `.momentum`, the
/// sequence would stay open until the app went inactive.
@MainActor @Suite struct InputEventRecordAppKitTests {
    @Test func momentumComesFirstAndItsEndIsItsOwnPhase() throws {
        // CGMomentumScrollPhase: 1 begin, 2 continue, 3 end (the CGEvent field has no cancelled value).
        #expect(try Self.phase(momentum: 1) == .momentum)
        #expect(try Self.phase(momentum: 2) == .momentum)
        #expect(try Self.phase(momentum: 3) == .momentumEnded)
        #expect(try Self.phase(scroll: 4, momentum: 2) == .momentum, "momentum before the gesture phase")
    }

    @Test func gesturePhasesMapOneToOne() throws {
        // CGScrollPhase: 1 began, 2 changed, 4 ended, 8 cancelled, 128 may begin.
        #expect(try Self.phase(scroll: 1) == .began)
        #expect(try Self.phase(scroll: 2) == .changed)
        #expect(try Self.phase(scroll: 4) == .ended)
        #expect(try Self.phase(scroll: 8) == .cancelled)
        #expect(try Self.phase(scroll: 128) == .mayBegin)
        #expect(try Self.phase() == InputScrollPhase.none, "a wheel notch has no phase")
    }

    /// The record's phase of a trackpad scroll whose CGEvent has gesture phase `scroll` and momentum
    /// phase `momentum`.
    private static func phase(scroll: Int64 = 0, momentum: Int64 = 0) throws -> InputScrollPhase {
        _ = NSApplication.shared
        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0))
        cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: scroll)
        cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        let event = try #require(NSEvent(cgEvent: cgEvent))
        return InputEventRecord(event, type: .scrollWheel).scrollPhase
    }
}

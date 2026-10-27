package import Foundation

/// Chromium's answer to one trackpad wheel a hosted page got (WHEEL_ACK, task p01-process-234 of
/// plans/cmux-next/chrome-parity/p01-process.md; the host's side is `ChromiumHost/src/host_wheel_ack.h`).
///
/// It carries the two answers Chrome's history swiper decides from
/// (`chrome/browser/renderer_host/chrome_render_widget_host_view_mac_history_swiper.mm`): whether the
/// wheel's scroll update scrolled anything (`-rendererHandledGestureScrollEvent:consumed:`, mojom
/// `GestureScrollEventAck`), and whether the page left the overscroll to the browser
/// (`-onOverscrolled:`, mojom `DidOverscroll`, its `overscroll_behavior.x`).
package nonisolated struct BrowserWheelAck: Equatable, Sendable {
    /// CSS `overscroll-behavior-x` of the scroller that ran out of room.
    package nonisolated enum OverscrollBehavior: Int64, Equatable, Sendable {
        case auto = 0
        case contain = 1
        /// CSS `none`: contain, and no overscroll affordance.
        case disabled = 2
    }

    /// The page ran out of room that way (`DidOverscroll`).
    package nonisolated struct Overscroll: Equatable, Sendable {
        /// Accumulated overscroll along x, in DIPs.
        package var x: CGFloat
        package var behaviorX: OverscrollBehavior

        package init(x: CGFloat, behaviorX: OverscrollBehavior) {
            self.x = x
            self.behaviorX = behaviorX
        }
    }

    /// The input seq of the wheel frame it answers (the page view's receipt).
    package var seq: UInt32
    /// The wheel made a scroll update, and this is that update's ack.
    package var scrollUpdate: Bool
    /// The page took the wheel: the update scrolled something, or a script's `preventDefault` took it.
    package var consumed: Bool
    /// DIPs the page scrolled for it.
    package var consumedX: CGFloat
    package var consumedY: CGFloat
    /// Set when `DidOverscroll` came with it.
    package var overscroll: Overscroll?

    package init(seq: UInt32, scrollUpdate: Bool, consumed: Bool, consumedX: CGFloat = 0, consumedY: CGFloat = 0,
                 overscroll: Overscroll? = nil) {
        self.seq = seq
        self.scrollUpdate = scrollUpdate
        self.consumed = consumed
        self.consumedX = consumedX
        self.consumedY = consumedY
        self.overscroll = overscroll
    }

    /// `kWheelAckUpdate`, `kWheelAckConsumed`, `kWheelAckOverscrolled` and `kWheelAckBehaviorShift`.
    private static let updateBit: Int64 = 1 << 0
    private static let consumedBit: Int64 = 1 << 1
    private static let overscrolledBit: Int64 = 1 << 2
    private static let behaviorShift: Int64 = 8

    /// A WHEEL_ACK event's fields: `request` the seq, `a` the scrolled DIPs in hundredths (x in the
    /// low 32 bits, y in the high), `b` the flags in the low 32 bits and the overscroll's x in
    /// hundredths in the high. An unknown overscroll behavior reads as ``OverscrollBehavior/disabled``: the page keeps it.
    package init(request: Int32, a: Int64, b: Int64) {
        let overscrolled = b & Self.overscrolledBit != 0
        self.init(seq: UInt32(bitPattern: request), scrollUpdate: b & Self.updateBit != 0, consumed: b & Self.consumedBit != 0,
                  consumedX: Self.hundredths(Int32(truncatingIfNeeded: a)),
                  consumedY: Self.hundredths(Int32(truncatingIfNeeded: a >> 32)),
                  overscroll: overscrolled
                      ? Overscroll(x: Self.hundredths(Int32(truncatingIfNeeded: b >> 32)),
                                   behaviorX: OverscrollBehavior(rawValue: (b >> Self.behaviorShift) & 3) ?? .disabled)
                      : nil)
    }

    private static func hundredths(_ value: Int32) -> CGFloat {
        CGFloat(value) / 100
    }
}

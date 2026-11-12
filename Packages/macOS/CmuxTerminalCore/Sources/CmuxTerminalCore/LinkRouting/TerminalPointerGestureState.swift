public import Foundation

/// Tracks one accepted terminal left-button gesture from press through release.
///
/// A gesture can complete only in the window where it began and at a timestamp
/// no earlier than its press. Completion always clears the pending state, so a
/// rejected release cannot be reused by a later event.
public struct TerminalPointerGestureState: Equatable, Sendable {
    /// Returns the number of asynchronous clipboard callbacks a completed gesture may produce.
    ///
    /// A drag produces one copy. A repeated click produces one callback for
    /// the word selection and another for the line selection; the count is
    /// bounded so an unusual AppKit click count cannot create an unbounded
    /// clipboard admission window.
    ///
    /// - Parameters:
    ///   - isDrag: Whether pointer motion completed a drag selection.
    ///   - clickCount: AppKit's click count for the release event.
    ///   - isShiftClick: Whether Shift was held for a single-click selection.
    /// - Returns: The bounded callback count, or zero for a plain click.
    public static func clipboardWriteCount(
        isDrag: Bool,
        clickCount: Int,
        isShiftClick: Bool = false
    ) -> Int {
        guard isDrag || clickCount > 1 || isShiftClick else { return 0 }
        guard clickCount > 1 else { return 1 }
        return min(max(clickCount - 1, 1), 3)
    }

    /// Minimum pointer displacement that commits a drag selection.
    private static let dragThresholdSquared = 9.0

    /// The press-time authorization captured for a matched release.
    public typealias Completion = (
        modifierFlagsRawValue: UInt,
        permitsLinkActivation: Bool,
        isDrag: Bool
    )

    private enum Phase: Equatable, Sendable {
        case idle
        case pressed(
            windowNumber: Int,
            timestamp: TimeInterval,
            modifierFlagsRawValue: UInt,
            permitsLinkActivation: Bool,
            pressPointX: Double,
            pressPointY: Double,
            isDrag: Bool
        )
    }

    private var phase: Phase = .idle

    /// Creates an idle gesture state.
    public init() {}

    /// Whether a terminal release is still required to balance an accepted press.
    public var hasPendingRelease: Bool {
        if case .pressed = phase { return true }
        return false
    }

    /// Whether the current gesture has moved far enough to be a selection drag.
    public var isDrag: Bool {
        if case let .pressed(_, _, _, _, _, _, isDrag) = phase { return isDrag }
        return false
    }

    /// The modifier flags captured by the pending press, if one exists.
    public var pendingModifierFlagsRawValue: UInt? {
        guard case let .pressed(_, _, modifierFlagsRawValue, _, _, _, _) = phase else { return nil }
        return modifierFlagsRawValue
    }

    /// Begins a gesture and replaces any unfinished gesture.
    ///
    /// - Parameters:
    ///   - windowNumber: The window that received the press.
    ///   - timestamp: The press event timestamp.
    ///   - modifierFlagsRawValue: Modifiers captured at press time.
    ///   - permitsLinkActivation: Whether the press may authorize a link.
    ///   - pressPointX: The press location in the terminal view's x-axis.
    ///   - pressPointY: The press location in the terminal view's y-axis.
    public mutating func begin(
        windowNumber: Int,
        timestamp: TimeInterval,
        modifierFlagsRawValue: UInt,
        permitsLinkActivation: Bool,
        pressPointX: Double = 0,
        pressPointY: Double = 0
    ) {
        phase = .pressed(
            windowNumber: windowNumber,
            timestamp: timestamp,
            modifierFlagsRawValue: modifierFlagsRawValue,
            permitsLinkActivation: permitsLinkActivation,
            pressPointX: pressPointX,
            pressPointY: pressPointY,
            isDrag: false
        )
    }

    /// Records pointer motion after it crosses the drag-selection threshold.
    public mutating func markDragged(atX x: Double, y: Double) {
        guard case let .pressed(
            windowNumber,
            timestamp,
            modifierFlagsRawValue,
            permitsLinkActivation,
            pressPointX,
            pressPointY,
            isDrag
        ) = phase else { return }
        guard !isDrag,
              (x - pressPointX) * (x - pressPointX)
                + (y - pressPointY) * (y - pressPointY) >= Self.dragThresholdSquared else { return }
        phase = .pressed(
            windowNumber: windowNumber,
            timestamp: timestamp,
            modifierFlagsRawValue: modifierFlagsRawValue,
            permitsLinkActivation: permitsLinkActivation,
            pressPointX: pressPointX,
            pressPointY: pressPointY,
            isDrag: true
        )
    }

    /// Revokes link authorization while retaining the balancing terminal release.
    public mutating func invalidateLinkActivation() {
        guard case let .pressed(
            windowNumber,
            timestamp,
            modifierFlagsRawValue,
            _,
            pressPointX,
            pressPointY,
            isDrag
        ) = phase else {
            return
        }
        phase = .pressed(
            windowNumber: windowNumber,
            timestamp: timestamp,
            modifierFlagsRawValue: modifierFlagsRawValue,
            permitsLinkActivation: false,
            pressPointX: pressPointX,
            pressPointY: pressPointY,
            isDrag: isDrag
        )
    }

    /// Completes and clears the pending gesture when the release matches its press.
    ///
    /// - Parameters:
    ///   - windowNumber: The window that received the release.
    ///   - timestamp: The release event timestamp.
    /// - Returns: The press-time authorization, or `nil` for an unmatched release.
    public mutating func complete(windowNumber: Int, timestamp: TimeInterval) -> Completion? {
        guard case let .pressed(
            pressWindowNumber,
            pressTimestamp,
            modifierFlagsRawValue,
            permitsLinkActivation,
            _,
            _,
            isDrag
        ) = phase else {
            return nil
        }
        phase = .idle
        guard pressWindowNumber == windowNumber, timestamp >= pressTimestamp else { return nil }
        return (modifierFlagsRawValue, permitsLinkActivation, isDrag)
    }

    /// Clears any pending gesture without producing a release authorization.
    public mutating func cancel() {
        phase = .idle
    }
}

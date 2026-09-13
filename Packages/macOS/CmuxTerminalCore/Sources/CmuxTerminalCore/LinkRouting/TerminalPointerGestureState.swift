public import Foundation

/// Tracks one accepted terminal left-button gesture from press through release.
///
/// A gesture can complete only in the window where it began and at a timestamp
/// no earlier than its press. Completion always clears the pending state, so a
/// rejected release cannot be reused by a later event.
public struct TerminalPointerGestureState: Equatable, Sendable {
    /// The press-time authorization captured for a matched release.
    public typealias Completion = (
        modifierFlagsRawValue: UInt,
        permitsLinkActivation: Bool
    )

    private enum Phase: Equatable, Sendable {
        case idle
        case pressed(
            windowNumber: Int,
            timestamp: TimeInterval,
            modifierFlagsRawValue: UInt,
            permitsLinkActivation: Bool
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

    /// The modifier flags captured by the pending press, if one exists.
    public var pendingModifierFlagsRawValue: UInt? {
        guard case let .pressed(_, _, modifierFlagsRawValue, _) = phase else { return nil }
        return modifierFlagsRawValue
    }

    /// Begins a gesture and replaces any unfinished gesture.
    ///
    /// - Parameters:
    ///   - windowNumber: The window that received the press.
    ///   - timestamp: The press event timestamp.
    ///   - modifierFlagsRawValue: Modifiers captured at press time.
    ///   - permitsLinkActivation: Whether the press may authorize a link.
    public mutating func begin(
        windowNumber: Int,
        timestamp: TimeInterval,
        modifierFlagsRawValue: UInt,
        permitsLinkActivation: Bool
    ) {
        phase = .pressed(
            windowNumber: windowNumber,
            timestamp: timestamp,
            modifierFlagsRawValue: modifierFlagsRawValue,
            permitsLinkActivation: permitsLinkActivation
        )
    }

    /// Revokes link authorization while retaining the balancing terminal release.
    public mutating func invalidateLinkActivation() {
        guard case let .pressed(windowNumber, timestamp, modifierFlagsRawValue, _) = phase else {
            return
        }
        phase = .pressed(
            windowNumber: windowNumber,
            timestamp: timestamp,
            modifierFlagsRawValue: modifierFlagsRawValue,
            permitsLinkActivation: false
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
            permitsLinkActivation
        ) = phase else {
            return nil
        }
        phase = .idle
        guard pressWindowNumber == windowNumber, timestamp >= pressTimestamp else { return nil }
        return (modifierFlagsRawValue, permitsLinkActivation)
    }

    /// Clears any pending gesture without producing a release authorization.
    public mutating func cancel() {
        phase = .idle
    }
}

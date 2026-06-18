public import Foundation

/// Pure reducer for the terminal input bar's armed/sticky modifier state.
///
/// Models the four accessory modifiers (`control`, `alternate`, `command`,
/// `shift`) each of which can be *armed* (applies to the next key, then
/// disarms) or *sticky* (stays armed until tapped off). A double-tap within
/// ``stickyDoubleTapInterval`` promotes an armed modifier to sticky. At most
/// one modifier is ever armed/sticky at a time.
///
/// Extracted verbatim from the four near-identical `toggle*Modifier` methods
/// in the iOS input view so the state machine is table-testable without a
/// `UITextView` or `Date`-driven timers (the caller supplies the tap time).
public struct TerminalInputModifierState: Equatable, Sendable {
    /// The default double-tap window for promoting an armed modifier to sticky.
    public static let stickyDoubleTapInterval: TimeInterval = 0.4

    private var armed: TerminalInputModifier?
    private var isSticky: Bool = false
    private var lastTapTime: TimeInterval?

    /// Creates a state with no modifier armed.
    public init() {}

    /// The currently armed (or sticky) modifier, if any.
    public var armedModifier: TerminalInputModifier? { armed }

    /// Whether `modifier` is currently armed (armed or sticky).
    /// - Parameter modifier: The modifier to query.
    /// - Returns: `true` when this modifier will apply to the next key.
    public func isArmed(_ modifier: TerminalInputModifier) -> Bool {
        armed == modifier
    }

    /// Whether `modifier` is currently sticky (stays armed across keys).
    /// - Parameter modifier: The modifier to query.
    /// - Returns: `true` when this modifier is locked on.
    public func isStickyOn(_ modifier: TerminalInputModifier) -> Bool {
        armed == modifier && isSticky
    }

    /// Disarms every modifier (used by zoom and remote-mode changes).
    public mutating func disarmAll() {
        armed = nil
        isSticky = false
        lastTapTime = nil
    }

    /// Applies a tap on `modifier` at time `now`, matching the legacy toggle
    /// semantics:
    ///
    /// - Tapping a sticky modifier turns everything off.
    /// - Tapping an already-armed (non-sticky) modifier within
    ///   ``stickyDoubleTapInterval`` promotes it to sticky.
    /// - Otherwise the tap arms this modifier fresh (disarming any other) when
    ///   it was off, or turns it off when it was the lone armed one.
    ///
    /// - Parameters:
    ///   - modifier: The tapped modifier.
    ///   - now: The current monotonic time of the tap.
    public mutating func tap(_ modifier: TerminalInputModifier, now: TimeInterval, interval: TimeInterval = stickyDoubleTapInterval) {
        let stickyForThis = armed == modifier && isSticky
        if stickyForThis {
            disarmAll()
            return
        }
        if armed == modifier, !isSticky, let last = lastTapTime, now - last < interval {
            isSticky = true
            lastTapTime = nil
            return
        }
        let wasArmed = armed == modifier
        let shouldArm = !wasArmed
        disarmAll()
        if shouldArm {
            armed = modifier
            lastTapTime = now
        }
    }

    /// Clears the pending double-tap window without changing armed/sticky state.
    ///
    /// A subsequent ``tap(_:now:interval:)`` on the currently armed modifier is
    /// then treated as a fresh single tap rather than a sticky promotion. Used
    /// by deterministic tests that drive taps without controlling wall-clock
    /// time.
    public mutating func clearDoubleTapWindow() {
        lastTapTime = nil
    }

    /// Consumes a one-shot (non-sticky) modifier after it applies to a key.
    ///
    /// Disarms the active modifier unless it is sticky. The UI calls this after
    /// encoding a key with the armed modifier so a single tap applies exactly
    /// once while a sticky lock persists.
    ///
    /// - Parameter modifier: The modifier that was applied.
    public mutating func consumeIfNotSticky(_ modifier: TerminalInputModifier) {
        guard armed == modifier, !isSticky else { return }
        disarmAll()
    }
}

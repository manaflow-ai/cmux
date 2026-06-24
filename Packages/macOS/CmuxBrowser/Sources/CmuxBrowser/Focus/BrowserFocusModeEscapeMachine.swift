public import AppKit
public import Foundation

/// The pure event-decision logic for the browser focus-mode plain-Escape
/// "double-tap to exit" machine, lifted out of `BrowserPanel` as a value type.
///
/// Browser focus mode forwards the first plain Escape to the page and arms an
/// exit; a second plain Escape within `escapeSequenceInterval` of the arming
/// event exits focus mode, while a later second Escape re-arms from the new
/// timestamp. AppKit can deliver the same physical Escape through more than one
/// responder path, so a per-event fingerprint collapses duplicate deliveries and
/// `isARepeat` events never count toward the exit.
///
/// This type owns only the transient arming state (the arm timestamp and the
/// last-seen plain-Escape fingerprint). It performs no I/O, posts no
/// notifications, and never touches the panel's published `isBrowserFocusModeActive`
/// or `isBrowserFocusModeExitArmed` mirrors. The owning panel mirrors its state
/// in, calls ``decide(event:isActive:isExitArmed:)``, then applies the returned
/// ``Outcome``: it adopts the returned machine state, performs the requested
/// clears (which own the notifications, logging, and the `isActive` mutation),
/// emits the requested debug markers, and returns the decision to its caller.
/// Eligibility (`canEnterBrowserFocusMode`) and the actual focus mutations stay
/// app-side; this machine assumes the panel has already gated on eligibility.
public struct BrowserFocusModeEscapeMachine: Sendable, Equatable {
    /// The maximum gap between the arming plain Escape and the exiting plain
    /// Escape for the second tap to exit rather than re-arm.
    public static let escapeSequenceInterval: TimeInterval = 1.6

    /// The timestamp of the plain Escape that armed the pending exit, if armed.
    public private(set) var exitArmedAt: TimeInterval?

    /// The fingerprint of the most recent plain Escape, used to collapse
    /// duplicate AppKit deliveries of the same physical event.
    public private(set) var lastPlainEscapeFingerprint: BrowserFocusModePlainEscapeEventFingerprint?

    /// Creates a machine seeded from the panel's current arming state.
    public init(
        exitArmedAt: TimeInterval? = nil,
        lastPlainEscapeFingerprint: BrowserFocusModePlainEscapeEventFingerprint? = nil
    ) {
        self.exitArmedAt = exitArmedAt
        self.lastPlainEscapeFingerprint = lastPlainEscapeFingerprint
    }

    /// A clear the panel must perform, expressed as the panel method to call.
    ///
    /// Each case names the exact panel clear the legacy handler invoked. The
    /// panel owns these methods (they post `browserFocusModeStateDidChange`, emit
    /// the clear/disarm debug logs, and mutate `isBrowserFocusModeActive`/
    /// `isBrowserFocusModeExitArmed`), so the machine requests them by intent
    /// rather than reimplementing their effects. The associated `reasonSuffix`
    /// is appended to the caller's `reason` exactly as the legacy code did.
    ///
    /// When an outcome carries a clear, the returned `machine` is the PRE-clear
    /// state (matching the legacy code, which assigned the fingerprint and left
    /// the arm timestamp in place right up to the clear call). The panel adopts
    /// that state, then runs the panel clear method, which is what nulls the
    /// machine's fields (the panel's clears own that reset, just as they own the
    /// published mirrors, the notification, and the log line). This preserves the
    /// legacy `clearBrowserFocusModeExitArm` disarm-log condition, which fired on
    /// `exitArmedAt != nil` even when the published mirror was already `false`.
    public enum ClearRequest: Sendable, Equatable {
        /// Call `clearBrowserFocusMode(reason: reason + reasonSuffix)`.
        case focusMode(reasonSuffix: String)

        /// Call `clearBrowserFocusModeEscapeArms(reason: reason + reasonSuffix)`.
        case escapeArms(reasonSuffix: String)
    }

    /// A `#if DEBUG` log marker the panel should emit, matching the legacy log
    /// lines one-for-one (the panel supplies its own `panel=…`/`reason=…`
    /// context).
    public enum DebugMarker: Sendable, Equatable {
        /// `browser.focusMode.escape.repeat`
        case escapeRepeat
        /// `browser.focusMode.escape.duplicate`
        case escapeDuplicate
        /// `browser.focusMode.escape.rearm`
        case escapeRearm
        /// `browser.focusMode.escape.arm`
        case escapeArm

        /// The exact legacy log event token for this marker, e.g.
        /// `browser.focusMode.escape.arm`.
        public var logEvent: String {
            switch self {
            case .escapeRepeat: "browser.focusMode.escape.repeat"
            case .escapeDuplicate: "browser.focusMode.escape.duplicate"
            case .escapeRearm: "browser.focusMode.escape.rearm"
            case .escapeArm: "browser.focusMode.escape.arm"
            }
        }
    }

    /// The full result of feeding one key event to the machine: the verdict, the
    /// next machine state to adopt, the panel clears to perform, and any debug
    /// markers to emit. The panel applies these in order: adopt `machine`,
    /// perform `clears`, emit `debugMarkers`, return `decision`.
    public struct Outcome: Sendable, Equatable {
        /// The routing verdict for the event.
        public let decision: BrowserFocusModeKeyDecision

        /// The machine state the panel should adopt.
        public let machine: BrowserFocusModeEscapeMachine

        /// `true` when this event armed (or re-armed) the pending exit, so the
        /// panel must set `isBrowserFocusModeExitArmed = true`. Matches the legacy
        /// handler's `isBrowserFocusModeExitArmed = true` on the first-tap arm and
        /// the no-op re-assert on the re-arm path. Never `true` together with a
        /// clear (the clears own setting the mirror to `false`).
        public let armsExit: Bool

        /// Panel clears to perform (in order) before returning.
        public let clears: [ClearRequest]

        /// `#if DEBUG` markers the panel should log.
        public let debugMarkers: [DebugMarker]

        public init(
            decision: BrowserFocusModeKeyDecision,
            machine: BrowserFocusModeEscapeMachine,
            armsExit: Bool = false,
            clears: [ClearRequest] = [],
            debugMarkers: [DebugMarker] = []
        ) {
            self.decision = decision
            self.machine = machine
            self.armsExit = armsExit
            self.clears = clears
            self.debugMarkers = debugMarkers
        }
    }

    /// Whether the machine currently holds any arming state (an arm timestamp or
    /// a remembered fingerprint), mirroring the legacy `clearBrowserFocusMode`
    /// guard's `browserFocusModeExitArmedAt != nil || lastFingerprint != nil`.
    public var hasArmingState: Bool {
        exitArmedAt != nil || lastPlainEscapeFingerprint != nil
    }

    /// Whether an exit is currently armed by timestamp, mirroring the legacy
    /// `clearBrowserFocusModeExitArm` guard's `browserFocusModeExitArmedAt != nil`.
    public var hasArmedExitTimestamp: Bool {
        exitArmedAt != nil
    }

    /// A fully reset machine (no arm timestamp, no remembered fingerprint),
    /// matching the legacy `clearBrowserFocusMode` /
    /// `clearBrowserFocusModeEscapeArms` reset of both fields.
    public func cleared() -> BrowserFocusModeEscapeMachine {
        BrowserFocusModeEscapeMachine()
    }

    /// A machine with only the arm timestamp dropped, preserving the remembered
    /// fingerprint, matching the legacy `clearBrowserFocusModeExitArm` (which
    /// nulls `browserFocusModeExitArmedAt` and leaves the fingerprint intact).
    public func disarmedExitTimestamp() -> BrowserFocusModeEscapeMachine {
        var next = self
        next.exitArmedAt = nil
        return next
    }

    /// Whether a plain Escape arrived within the sequence window of the arming
    /// event, so the second tap exits rather than re-arms.
    ///
    /// Mirrors the legacy `browserFocusModeEscapeArmIsFresh(for:)`: an unset arm
    /// is never fresh; a non-positive arm or event timestamp is treated as fresh
    /// (the clock is unreliable, so do not force a re-arm); otherwise the gap
    /// must be within ``escapeSequenceInterval``.
    public func escapeArmIsFresh(eventTimestamp: TimeInterval) -> Bool {
        guard let startedAt = exitArmedAt else { return false }
        guard startedAt > 0, eventTimestamp > 0 else { return true }
        return max(0, eventTimestamp - startedAt) <= Self.escapeSequenceInterval
    }

    /// Decides how a key event reaching the focused web view should be routed,
    /// returning the verdict, the next machine state, and the side effects the
    /// panel must apply.
    ///
    /// `isActive`/`isExitArmed` are the panel's current published mirrors. The
    /// machine never mutates those mirrors itself; when the verdict needs them
    /// changed it requests a panel clear (which owns that mutation), and for the
    /// first-tap arm it surfaces the new `exitArmedAt` through the returned
    /// ``Outcome/machine`` and ``Outcome/armsExit`` (the panel sets
    /// `isBrowserFocusModeExitArmed` and adopts the machine). On a clear-free
    /// outcome the returned `machine` is the authoritative next state; on a
    /// clear-bearing outcome it is the PRE-clear state and the panel's clear
    /// resets the fields (see ``ClearRequest``). This is a faithful lift of
    /// `handleBrowserFocusModeKeyEvent(_:reason:)` after its eligibility guard.
    public func decide(
        event: NSEvent,
        isActive: Bool,
        isExitArmed: Bool
    ) -> Outcome {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        let isPlainEscape = flags.isEmpty && event.keyCode == 53

        guard isPlainEscape else {
            // Legacy: lastFingerprint = nil (arm timestamp left in place), then
            // clearBrowserFocusModeEscapeArms performs the actual reset + disarm
            // log. Pre-clear state keeps exitArmedAt so the panel's disarm log
            // condition still fires.
            var next = self
            next.lastPlainEscapeFingerprint = nil
            return Outcome(
                decision: isActive ? .forwardToWebView : .inactive,
                machine: next,
                clears: [.escapeArms(reasonSuffix: ".nonEscape")]
            )
        }

        guard isActive else {
            // Legacy: lastFingerprint = nil, then clearBrowserFocusModeEscapeArms.
            var next = self
            next.lastPlainEscapeFingerprint = nil
            return Outcome(
                decision: .inactive,
                machine: next,
                clears: [.escapeArms(reasonSuffix: ".inactiveEscape")]
            )
        }

        guard !event.isARepeat else {
            return Outcome(
                decision: .consume,
                machine: self,
                debugMarkers: [.escapeRepeat]
            )
        }

        let eventFingerprint = BrowserFocusModePlainEscapeEventFingerprint(event)
        if lastPlainEscapeFingerprint == eventFingerprint {
            return Outcome(
                decision: .consume,
                machine: self,
                debugMarkers: [.escapeDuplicate]
            )
        }

        var next = self
        next.lastPlainEscapeFingerprint = eventFingerprint

        if isExitArmed {
            if escapeArmIsFresh(eventTimestamp: event.timestamp) {
                // Legacy: lastFingerprint = eventFingerprint (already set on `next`,
                // arm timestamp left in place), then clearBrowserFocusMode performs
                // the reset + clears isActive/isExitArmed. Pre-clear state.
                return Outcome(
                    decision: .consume,
                    machine: next,
                    clears: [.focusMode(reasonSuffix: ".escapeExit")]
                )
            }

            next.exitArmedAt = event.timestamp
            return Outcome(
                decision: .forwardToWebView,
                machine: next,
                armsExit: true,
                debugMarkers: [.escapeRearm]
            )
        }

        next.exitArmedAt = event.timestamp
        return Outcome(
            decision: .forwardToWebView,
            machine: next,
            armsExit: true,
            debugMarkers: [.escapeArm]
        )
    }
}

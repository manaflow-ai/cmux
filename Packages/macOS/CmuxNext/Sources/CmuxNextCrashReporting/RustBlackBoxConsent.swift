import CmuxNextCompat

/// Whether a forwarded Rust crash may carry its black box (``RustCrashArtifacts/blackboxOptIn``): hang reports are
/// on in effect, as the app's hang-reports controller decided (a build that sends, the setting on, this Mac's
/// consent record, no managed `DisableTelemetry`), and the consent record is still there. The record alone never
/// counts: a file edit that turned the setting off while cmux was not running, or a channel that never sends,
/// leaves one that only the controller's decision overrides.
///
/// ```swift
/// let consent = RustBlackBoxConsent(consentRecorded: { defaults.object(forKey: key) is Date })
/// consent.decide(true)  // true: the first decision (the forwarder starts then)
/// consent.allows        // read on the forwarder's queue at each Rust crash
/// ```
public final class RustBlackBoxConsent: Sendable {
    private enum State: UInt8 {
        case undecided, off, on
    }

    private let state = Atomic<UInt8>(State.undecided.rawValue)
    private let consentRecorded: @Sendable () -> Bool

    /// - Parameter consentRecorded: Whether this Mac's hang-reports consent record exists now.
    public init(consentRecorded: @escaping @Sendable () -> Bool) {
        self.consentRecorded = consentRecorded
    }

    /// The controller's decision: reports on or off. Returns whether it is the first one.
    @discardableResult
    public func decide(_ on: Bool) -> Bool {
        let original = state.exchange((on ? State.on : State.off).rawValue, ordering: .acquiringAndReleasing)
        return original == State.undecided.rawValue
    }

    /// Whether a black box may leave the Mac now: false before the controller's first decision.
    public var allows: Bool {
        state.load(ordering: .acquiring) == State.on.rawValue && consentRecorded()
    }
}

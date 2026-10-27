import CmuxNextCompat
#if canImport(MetricKit)
public import MetricKit
#endif

/// Mirrors catalog intervals to MetricKit while opt-in hang reports are on
/// (plans/cmux-next/hang-reports-DESIGN.md section 2).
///
/// MetricKit aggregates only `mxSignpost` intervals on a log from
/// `MXMetricManager.makeLogHandle(category:)`, never `OSSignposter` intervals. While ``isOn``, each
/// ``Signposter`` begin and end of a mirrored name (``mirrors(_:)``) is repeated there with the
/// catalog name and no message, so MetricKit returns a duration histogram per name
/// (`MXSignpostMetric`). Off (the default), the cost per interval is one relaxed atomic load; on,
/// two `mxSignpost` events and no lock. Where MetricKit does not exist (Linux) the switch is kept and nothing
/// is mirrored: ``begin(_:)`` returns nil.
///
/// ```swift
/// SignpostMetricKitMirror.shared.setOn(settings.hangReports)
/// ```
public final class SignpostMetricKitMirror: Sendable {
    /// The mirror every ``Signposter`` reads.
    // singleton-allow: MetricKit's log handles are process-wide, and Signposter's static per-category handles (read at every action, with no injection path) must all see one switch.
    public static let shared = SignpostMetricKitMirror()

    private let on = Atomic<Bool>(false)

    #if canImport(MetricKit)
    /// One MetricKit log per category of a mirrored name, made at the first read (``setOn(_:)`` with true,
    /// never while off).
    // crash-allow: OSLog handles are immutable and thread-safe (OSLog is not marked Sendable); a static let is initialized once (dispatch_once) and never written, so readers need no lock.
    nonisolated(unsafe) private static let logs: [SignpostCategory: OSLog] = Dictionary(
        Set(SignpostName.allCases.filter(mirrors).map(\.traceCategory))
            .map { ($0, MXMetricManager.makeLogHandle(category: $0.rawValue)) }, uniquingKeysWith: { first, _ in first })
    #endif

    init() {}

    /// Whether intervals are mirrored.
    public var isOn: Bool { on.load(ordering: .relaxed) }

    /// Turns mirroring on (hang reports on) or off.
    public func setOn(_ value: Bool) {
        #if canImport(MetricKit)
        if value { _ = Self.logs }
        #endif
        on.store(value, ordering: .relaxed)
    }

    /// Whether `name` is mirrored: an allowlist of the action, switch, create and launch intervals and the
    /// other once-per-gesture intervals. A name added to the catalog is not mirrored until it is listed here:
    /// per-frame, per-hop, per-pump-pass and per-scroll-event names never are (Apple advises against
    /// high-frequency custom MetricKit signposts), nor is the `stall` category, which a report leaves out
    /// (the watchdog reports stalls itself).
    public static func mirrors(_ name: SignpostName) -> Bool {
        switch name {
        case .actionPerform, .actionCommit, .actionGate, .motionRun, .keyToFrame, .keyFlow, .switchWorkspace,
             .switchTab, .switchPaneFocus, .switchAppActivation, .createTab, .createWorkspace, .cefCreateBrowser,
             .launchProcessToMain, .launchFirstWindow, .launchFirstFrame, .launchDaemonReady,
             .launchFirstTerminalOutput:
            true
        default: false
        }
    }

    /// Mirrors a begin; returns the id the end needs, nil while off or for a name not mirrored.
    func begin(_ name: SignpostName) -> OSSignpostID? {
        #if canImport(MetricKit)
        guard isOn, Self.mirrors(name), let log = Self.logs[name.traceCategory] else { return nil }
        let id = OSSignpostID(log: log)
        mxSignpost(.begin, log: log, name: name.staticName, signpostID: id)
        return id
        #else
        return nil
        #endif
    }

    /// Mirrors the end of an interval whose begin was mirrored (even if mirroring went off since).
    func end(_ name: SignpostName, id: OSSignpostID) {
        #if canImport(MetricKit)
        guard let log = Self.logs[name.traceCategory] else { return }
        mxSignpost(.end, log: log, name: name.staticName, signpostID: id)
        #endif
    }
}

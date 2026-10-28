import CmuxNextCompat
public import MetricKit
public import os

/// Mirrors catalog intervals to MetricKit while opt-in hang reports are on
/// (plans/cmux-next/hang-reports-DESIGN.md section 2).
///
/// MetricKit aggregates only `mxSignpost` intervals on a log from
/// `MXMetricManager.makeLogHandle(category:)`, never `OSSignposter` intervals. While ``isOn``, each
/// ``Signposter`` begin and end of a mirrored name (``mirrors(_:)``) is repeated there with the
/// catalog name and no message, so MetricKit returns a duration histogram per name
/// (`MXSignpostMetric`). Off (the default), the cost per interval is one relaxed atomic load; on,
/// two `mxSignpost` events and no lock.
///
/// ```swift
/// SignpostMetricKitMirror.shared.setOn(settings.hangReports)
/// ```
public final class SignpostMetricKitMirror: Sendable {
    /// The mirror every ``Signposter`` reads.
    // singleton-allow: MetricKit's log handles are process-wide, and Signposter's static per-category handles (read at every action, with no injection path) must all see one switch.
    public static let shared = SignpostMetricKitMirror()

    private let on = Atomic<Bool>(false)

    /// One MetricKit log per category, made at the first read (``setOn(_:)`` with true, never while off).
    // crash-allow: OSLog handles are immutable and thread-safe (OSLog is not marked Sendable); a static let is initialized once (dispatch_once) and never written, so readers need no lock.
    nonisolated(unsafe) private static let logs: [SignpostCategory: OSLog] = Dictionary(
        uniqueKeysWithValues: SignpostCategory.allCases.map { ($0, MXMetricManager.makeLogHandle(category: $0.rawValue)) })

    init() {}

    /// Whether intervals are mirrored.
    public var isOn: Bool { on.load(ordering: .relaxed) }

    /// Turns mirroring on (hang reports on) or off.
    public func setOn(_ value: Bool) {
        if value { _ = Self.logs }
        on.store(value, ordering: .relaxed)
    }

    /// Whether `name` is mirrored. Per-frame, per-pump-pass and per-scroll-event intervals are not
    /// (Apple advises against high-frequency custom MetricKit signposts), nor is the `stall`
    /// category, which a report leaves out (the watchdog reports stalls itself).
    public static func mirrors(_ name: SignpostName) -> Bool {
        switch name {
        case .motionFrame, .cefPump, .scrollToFrame, .stallMainTask: false
        default: name.category.map { $0 != .stall } ?? false
        }
    }

    /// Mirrors a begin; returns the id the end needs, nil while off or for a name not mirrored.
    func begin(_ name: SignpostName) -> OSSignpostID? {
        guard isOn, Self.mirrors(name), let category = name.category, let log = Self.logs[category] else { return nil }
        let id = OSSignpostID(log: log)
        mxSignpost(.begin, log: log, name: name.staticName, signpostID: id)
        return id
    }

    /// Mirrors the end of an interval whose begin was mirrored (even if mirroring went off since).
    func end(_ name: SignpostName, id: OSSignpostID) {
        guard let category = name.category, let log = Self.logs[category] else { return }
        mxSignpost(.end, log: log, name: name.staticName, signpostID: id)
    }
}

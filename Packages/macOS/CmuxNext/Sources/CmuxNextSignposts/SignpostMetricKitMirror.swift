import CmuxNextCompat
public import MetricKit
public import os

/// Mirrors catalog intervals to MetricKit while opt-in hang reports are on
/// (plans/cmux-next/hang-reports-DESIGN.md section 2).
///
/// MetricKit aggregates only `mxSignpost` intervals on a log from
/// `MXMetricManager.makeLogHandle(category:)`, never `OSSignposter` intervals. While ``isOn``, each
/// ``Signposter`` begin and end is repeated there with the catalog name and no message, so
/// MetricKit returns a duration histogram per name (`MXSignpostMetric`). Off (the default), the
/// cost per interval is one relaxed atomic load.
///
/// ```swift
/// SignpostMetricKitMirror.shared.setOn(settings.hangReports)
/// ```
public final class SignpostMetricKitMirror: Sendable {
    /// The mirror every ``Signposter`` reads.
    // singleton-allow: MetricKit's log handles are process-wide, and Signposter's static per-category handles (read at every action, with no injection path) must all see one switch.
    public static let shared = SignpostMetricKitMirror()

    private let on = Atomic<Bool>(false)
    /// One MetricKit log per category, made once.
    private let logs: [SignpostCategory: OSLog]

    init() {
        logs = Dictionary(uniqueKeysWithValues: SignpostCategory.allCases.map {
            ($0, MXMetricManager.makeLogHandle(category: $0.rawValue))
        })
    }

    /// Whether intervals are mirrored.
    public var isOn: Bool { on.load(ordering: .relaxed) }

    /// Turns mirroring on (hang reports on) or off.
    public func setOn(_ value: Bool) { on.store(value, ordering: .relaxed) }

    /// Mirrors a begin; returns the id the end needs, nil while off.
    func begin(_ name: SignpostName) -> OSSignpostID? {
        guard isOn, let log = logs[name.category] else { return nil }
        let id = OSSignpostID(log: log)
        mxSignpost(.begin, log: log, name: name.staticName, signpostID: id)
        return id
    }

    /// Mirrors the end of an interval whose begin was mirrored (even if mirroring went off since).
    func end(_ name: SignpostName, id: OSSignpostID) {
        guard let log = logs[name.category] else { return }
        mxSignpost(.end, log: log, name: name.staticName, signpostID: id)
    }
}

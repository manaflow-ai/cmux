import Foundation

/// Which Release signpost intervals a hang report may carry (PL-arch's always-on catalog,
/// `CmuxNextSignposts`, subsystem `com.cmuxterm.app.next`). MetricKit aggregates them
/// (`MXSignpostMetric`) only because `SignpostMetricKitMirror` repeats the catalog's intervals on
/// a MetricKit log while hang reports are on; an `OSSignposter` interval alone is not seen by it.
///
/// An interval reaches a report only when its category is one of ``categories`` (the catalog's
/// `stall` category is left out: the watchdog reports stalls itself) and its name is a static
/// identifier (``namePattern``, for example `switch.workspace`); the report carries its
/// histogram, never one event or its message.
///
/// ```swift
/// HangReportSignposts.allows(category: "motion", name: "motion.frame")  // true
/// ```
public nonisolated struct HangReportSignposts: Sendable {
    /// The catalog categories a report may carry.
    public static let categories: Set<String> = ["action", "motion", "key", "switch", "create", "cef", "launch"]
    /// The characters and length an interval name may have.
    public static let namePattern = #"^[a-z0-9_.\-]{1,48}$"#

    /// Makes the value from its parts.
    public init() {}

    /// Whether an interval of this category and name may be sent.
    public static func allows(category: String, name: String) -> Bool {
        categories.contains(category) && name.range(of: namePattern, options: .regularExpression) != nil
    }
}

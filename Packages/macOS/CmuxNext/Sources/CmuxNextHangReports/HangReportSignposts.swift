import Foundation
public import os
public import MetricKit

/// The Release signpost intervals a hang report may carry (PL-arch's always-on catalog,
/// `CmuxNextSignposts`: subsystem `com.cmuxterm.app.next`), and the MetricKit log handle that
/// makes MetricKit aggregate them (`MXSignpostMetric`; an `OSSignposter` interval on a normal log
/// is not seen by MetricKit, so the catalog mirrors its intervals to ``log(category:)`` only while
/// hang reports are on).
///
/// An interval reaches a report only when its category is one of ``categories`` (the catalog's
/// `stall` category is left out: the watchdog reports stalls itself) and its name is a static
/// identifier (``namePattern``, for example `switch.workspace`); the report carries its
/// histogram, never one event or its message.
///
/// ```swift
/// let log = HangReportSignposts().log(category: "motion")
/// mxSignpost(.begin, log: log, name: "motion.frame")
/// mxSignpost(.end, log: log, name: "motion.frame")
/// ```
public nonisolated struct HangReportSignposts: Sendable {
    /// The catalog categories a report may carry.
    public static let categories: Set<String> = ["action", "motion", "key", "switch", "create", "cef", "launch"]
    /// The characters and length an interval name may have.
    public static let namePattern = #"^[a-z0-9_.\-]{1,48}$"#

    public init() {}

    /// The MetricKit log handle of a catalog category.
    public func log(category: String) -> OSLog {
        MXMetricManager.makeLogHandle(category: category)
    }

    /// Whether an interval of this category and name may be sent.
    public static func allows(category: String, name: String) -> Bool {
        categories.contains(category) && name.range(of: namePattern, options: .regularExpression) != nil
    }
}

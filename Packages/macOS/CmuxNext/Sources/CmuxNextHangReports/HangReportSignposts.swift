import Foundation
public import os
public import MetricKit

/// The Release signpost intervals a hang report may carry, and the log handle that makes
/// MetricKit aggregate them (`MXSignpostMetric`; an `OSSignposter` interval is not seen by
/// MetricKit).
///
/// An interval reaches a report only when its category is one of ``categories`` and its name is
/// a static identifier (``namePattern``); the report carries its histogram, never one event.
///
/// ```swift
/// let log = HangReportSignposts().log(.motion)
/// mxSignpost(.begin, log: log, name: "frame")
/// mxSignpost(.end, log: log, name: "frame")
/// ```
public nonisolated struct HangReportSignposts: Sendable {
    /// One allowed category.
    public enum Category: String, Sendable, CaseIterable {
        /// Split, close, zoom and column motion frames.
        case motion = "perf.motion"
        /// Key to committed frame.
        case key = "perf.key"
        /// Workspace, tab and space switches.
        case switching = "perf.switch"
        /// New terminal, browser tab, workspace and window.
        case create = "perf.create"
        /// Chromium work on the main thread (pump passes, geometry).
        case cef = "perf.cef"
    }

    /// Every allowed category's raw value.
    public static let categories: Set<String> = Set(Category.allCases.map(\.rawValue))
    /// The characters and length an interval name may have.
    public static let namePattern = #"^[a-z0-9_.\-]{1,48}$"#

    public init() {}

    /// The MetricKit log handle of `category`.
    public func log(_ category: Category) -> OSLog {
        MXMetricManager.makeLogHandle(category: category.rawValue)
    }

    /// Whether an interval of this category and name may be sent.
    public static func allows(category: String, name: String) -> Bool {
        categories.contains(category) && name.range(of: namePattern, options: .regularExpression) != nil
    }
}

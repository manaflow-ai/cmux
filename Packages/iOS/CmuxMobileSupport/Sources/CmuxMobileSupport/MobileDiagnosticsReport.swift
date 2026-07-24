import Foundation

/// One diagnostics row shown in-app and copied into the plaintext report.
public struct MobileDiagnosticsReportRow: Equatable, Identifiable, Sendable {
    /// The row's health signal for the visual diagnostics list.
    public enum Status: Equatable, Sendable {
        /// The check is healthy.
        case pass
        /// The check found a user-actionable problem.
        case fail
        /// The check is informational.
        case info
    }

    /// Stable row identifier, reused as the accessibility identifier suffix.
    public let id: String
    /// User-facing row label.
    public let label: String
    /// User-facing row value.
    public let value: String
    /// The row's visual health.
    public let status: Status

    /// Creates a diagnostics row.
    /// - Parameters:
    ///   - id: Stable row identifier.
    ///   - label: User-facing row label.
    ///   - value: User-facing row value.
    ///   - status: Visual health for the row.
    public init(id: String, label: String, value: String, status: Status) {
        self.id = id
        self.label = label
        self.value = value
        self.status = status
    }
}

/// Value snapshot used to build a copied mobile diagnostics report.
public struct MobileDiagnosticsReportSnapshot: Equatable, Sendable {
    /// User-facing report title.
    public let title: String
    /// User-facing app-version label.
    public let appVersionLabel: String
    /// User-facing app version string.
    public let appVersion: String
    /// User-facing build-stamp label.
    public let buildStampLabel: String
    /// User-facing build stamp string.
    public let buildStamp: String
    /// Diagnostics rows in display order.
    public let rows: [MobileDiagnosticsReportRow]

    /// Creates a report snapshot.
    /// - Parameters:
    ///   - title: User-facing report title.
    ///   - appVersionLabel: User-facing app-version label.
    ///   - appVersion: User-facing app version string.
    ///   - buildStampLabel: User-facing build-stamp label.
    ///   - buildStamp: User-facing build stamp string.
    ///   - rows: Diagnostics rows in display order.
    public init(
        title: String,
        appVersionLabel: String,
        appVersion: String,
        buildStampLabel: String,
        buildStamp: String,
        rows: [MobileDiagnosticsReportRow]
    ) {
        self.title = title
        self.appVersionLabel = appVersionLabel
        self.appVersion = appVersion
        self.buildStampLabel = buildStampLabel
        self.buildStamp = buildStamp
        self.rows = rows
    }
}

/// Copyable plaintext diagnostics report.
public struct MobileDiagnosticsReport: Equatable, Sendable {
    /// The snapshot used to produce the report.
    public let snapshot: MobileDiagnosticsReportSnapshot
    /// Plaintext report suitable for the pasteboard.
    public let plainText: String

    /// Creates a plaintext report from a snapshot.
    /// - Parameter snapshot: Snapshot to format.
    public init(snapshot: MobileDiagnosticsReportSnapshot) {
        self.snapshot = snapshot
        var lines = [
            snapshot.title,
            "\(snapshot.appVersionLabel): \(snapshot.appVersion)",
            "\(snapshot.buildStampLabel): \(snapshot.buildStamp)",
            "",
        ]
        lines += snapshot.rows.map { "\($0.label): \($0.value)" }
        self.plainText = lines.joined(separator: "\n")
    }
}

/// Pure formatter for mobile diagnostics reports.
public struct MobileDiagnosticsReportBuilder: Sendable {
    /// Creates a report builder.
    public init() {}

    /// Builds a plaintext diagnostics report from a value snapshot.
    /// - Parameter snapshot: Snapshot containing localized report strings.
    /// - Returns: A formatted copyable report.
    public func build(from snapshot: MobileDiagnosticsReportSnapshot) -> MobileDiagnosticsReport {
        MobileDiagnosticsReport(snapshot: snapshot)
    }
}

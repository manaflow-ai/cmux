public import Foundation

/// Persists the most recent diagnostic snapshot across process launches.
///
/// The in-memory diagnostic ring dies with the process, so the events around
/// a connection drop were unrecoverable once the user relaunched before
/// exporting. The archive keeps exactly one previous-launch report on disk
/// (bounded, privacy-safe integers only, same vocabulary as the live ring) so
/// an export can include what happened before the current launch.
public struct DiagnosticReportArchive: Sendable {
    /// Upper bound for a stored report file; a report of maximum event count
    /// encodes far below this, so hitting it means corruption, not data.
    public static let maximumFileByteCount = 1_024 * 1_024

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Default location inside Application Support.
    public static func defaultArchive(
        fileManager: FileManager = .default
    ) -> DiagnosticReportArchive? {
        guard let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        do {
            try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return DiagnosticReportArchive(
            fileURL: base.appendingPathComponent("cmux-diagnostic-report.json")
        )
    }

    /// Atomically replaces the stored report. Empty reports are not worth a
    /// write and would only erase a more useful previous snapshot.
    public func save(_ report: DiagnosticReport) {
        guard !report.events.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(report),
              data.count <= Self.maximumFileByteCount else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Loads the previous process's report, or `nil` when absent or invalid.
    public func load() -> DiagnosticReport? {
        guard let data = try? Data(contentsOf: fileURL),
              data.count <= Self.maximumFileByteCount,
              let report = try? JSONDecoder().decode(DiagnosticReport.self, from: data),
              !report.events.isEmpty else { return nil }
        return report
    }

    /// Removes the stored report (sign-out / account erase).
    public func clear(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: fileURL)
    }
}

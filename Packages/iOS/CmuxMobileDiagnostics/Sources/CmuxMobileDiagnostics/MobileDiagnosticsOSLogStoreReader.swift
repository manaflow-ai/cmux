public import Foundation
import OSLog

/// `OSLogStore` reader scoped to the current process.
public struct MobileDiagnosticsOSLogStoreReader: MobileDiagnosticsOSLogReading {
    /// Optional subsystem prefix filter.
    public var subsystemPrefix: String?

    /// Create a unified-log reader.
    ///
    /// - Parameter subsystemPrefix: Optional subsystem prefix filter.
    public init(subsystemPrefix: String? = nil) {
        self.subsystemPrefix = subsystemPrefix
    }

    /// Read current-process unified-log entries.
    ///
    /// - Parameters:
    ///   - since: The oldest timestamp to include.
    ///   - limit: Maximum number of entries returned.
    /// - Returns: Log entries in chronological order.
    public func recentEntries(since: Date, limit: Int) throws -> [MobileDiagnosticsOSLogEntry] {
        guard limit > 0 else { return [] }
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: since)
        let entries = try store.getEntries(with: [], at: position, matching: nil)
        var ring: [MobileDiagnosticsOSLogEntry] = []
        ring.reserveCapacity(min(limit, 128))
        var nextIndex = 0
        for entry in entries {
            guard let log = entry as? OSLogEntryLog else { continue }
            if let subsystemPrefix, !log.subsystem.hasPrefix(subsystemPrefix) {
                continue
            }
            let diagnosticsEntry = MobileDiagnosticsOSLogEntry(
                date: log.date,
                subsystem: log.subsystem,
                category: log.category,
                level: levelName(log.level),
                message: ""
            )
            if ring.count < limit {
                ring.append(diagnosticsEntry)
            } else {
                ring[nextIndex] = diagnosticsEntry
                nextIndex = (nextIndex + 1) % limit
            }
        }
        if ring.count < limit || nextIndex == 0 {
            return ring
        }
        return Array(ring[nextIndex..<ring.count]) + Array(ring[0..<nextIndex])
    }

    private func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .undefined:
            return "undefined"
        case .debug:
            return "debug"
        case .info:
            return "info"
        case .notice:
            return "notice"
        case .error:
            return "error"
        case .fault:
            return "fault"
        @unknown default:
            return "unknown"
        }
    }
}

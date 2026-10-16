import Darwin
import Foundation
import os

enum StartupBreadcrumbLog {
    private static let maxFieldLength = 240
    private nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app", category: "StartupBreadcrumbLog")
    private static let reservedFieldKeys: Set<String> = [
        "timestamp",
        "timestampMs",
        "uptimeMs",
        "event",
        "pid",
        "bundleIdentifier",
        "appVersion",
        "build"
    ]

    static func append(_ event: String, fields: [String: String] = [:]) {
        guard isEnabled else { return }

        let now = Date()
        var payload: [String: Any] = [
            // `timestamp` keeps its original second-resolution ISO 8601 form for
            // existing readers; `timestampMs` and `uptimeMs` carry millisecond
            // timing so gaps between breadcrumbs inside one second are visible.
            "timestamp": ISO8601DateFormatter().string(from: now),
            "timestampMs": milliseconds(sinceEpochOf: now),
            "event": event,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown",
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        ]

        if let uptime = processUptimeMilliseconds(at: now) {
            payload["uptimeMs"] = uptime
        }

        for (key, value) in fields {
            let payloadKey = reservedFieldKeys.contains(key) ? "custom_\(key)" : key
            payload[payloadKey] = sanitized(value)
        }

        do {
            let url = logURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let line = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            guard flock(handle.fileDescriptor, LOCK_EX) == 0 else {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                throw POSIXError(code)
            }
            defer { flock(handle.fileDescriptor, LOCK_UN) }
            // Startup breadcrumbs are synchronous so the last edge survives immediate launch aborts.
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.write(contentsOf: Data([0x0A]))
        } catch {
            logger.fault("cmux startup breadcrumb failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Wall-clock time the kernel recorded for this process's launch, so
    /// `uptimeMs` includes dyld and pre-`main` work, not just time since the
    /// first breadcrumb.
    private nonisolated static let processStartDate: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()

    private static func milliseconds(sinceEpochOf date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func processUptimeMilliseconds(at date: Date) -> Int64? {
        guard let processStartDate else { return nil }
        return Int64((date.timeIntervalSince(processStartDate) * 1000).rounded())
    }

    private static var isEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["CMUX_DISABLE_STARTUP_BREADCRUMBS"] == "1" {
            return false
        }
        if environment["CMUX_STARTUP_BREADCRUMBS"] == "1" {
            return true
        }
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        return bundleIdentifier == "com.cmuxterm.app.nightly"
            || bundleIdentifier.hasPrefix("com.cmuxterm.app.nightly.")
            || bundleIdentifier == "com.cmuxterm.app.rc"
            || bundleIdentifier.hasPrefix("com.cmuxterm.app.rc.")
            || bundleIdentifier == "com.cmuxterm.app.debug"
            || bundleIdentifier.hasPrefix("com.cmuxterm.app.debug.")
    }

    private static var logURL: URL {
        let logsDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs/cmux", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("cmux-logs", isDirectory: true)
        let sanitizedBundleIdentifier = logFileComponent(Bundle.main.bundleIdentifier ?? "unknown")
        return logsDirectory.appendingPathComponent("startup-\(sanitizedBundleIdentifier).log")
    }

    private static func logFileComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return sanitized(value, maxLength: 160).unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
    }

    private static func sanitized(_ value: String, maxLength: Int = maxFieldLength) -> String {
        let flattened = value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        if flattened.count <= maxLength {
            return flattened
        }
        return String(flattened.prefix(maxLength)) + "...<truncated>"
    }
}

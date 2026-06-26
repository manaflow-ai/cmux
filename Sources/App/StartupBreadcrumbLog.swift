import Darwin
import Foundation
import os

enum StartupBreadcrumbLog {
    private static let maxFieldLength = 240
    private nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app", category: "StartupBreadcrumbLog")
    private static let reservedFieldKeys: Set<String> = [
        "timestamp",
        "event",
        "pid",
        "bundleIdentifier",
        "appVersion",
        "build"
    ]

    static func append(_ event: String, fields: [String: String] = [:]) {
        guard isEnabled else { return }

        var payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "event": event,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown",
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        ]

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

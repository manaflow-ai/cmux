import Foundation

enum StartupBreadcrumbLog {
    private static let lock = NSLock()
    private static let maxFieldLength = 240

    static func append(_ event: String, fields: [String: String] = [:]) {
        guard isEnabled else { return }

        lock.lock()
        defer { lock.unlock() }

        var payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "event": event,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown",
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        ]

        for (key, value) in fields {
            payload[key] = sanitized(value)
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
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.write(contentsOf: Data([0x0A]))
        } catch {
            NSLog("cmux startup breadcrumb failed: %@", String(describing: error))
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
            || bundleIdentifier.hasPrefix("com.cmuxterm.app.dev.")
    }

    private static var logURL: URL {
        let logsDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs/cmux", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("cmux-logs", isDirectory: true)
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unknown"
        let sanitizedBundleIdentifier = sanitized(bundleIdentifier, maxLength: 160)
            .replacingOccurrences(of: "/", with: "-")
        return logsDirectory.appendingPathComponent("startup-\(sanitizedBundleIdentifier).log")
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

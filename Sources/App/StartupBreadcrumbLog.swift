import Darwin
import Foundation
import os
import Sentry

enum StartupBreadcrumbLog {
    private static let maxFieldLength = 240
    static let maximumLogBytes = 256 * 1024
    static let maximumTailLines = 100
    static let maximumTailBytes = 16 * 1024
    private nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app", category: "StartupBreadcrumbLog")
    private static let reservedFieldKeys: Set<String> = [
        "timestamp",
        "event",
        "pid",
        "bundleIdentifier",
        "appVersion",
        "build"
    ]

    struct Configuration {
        let environment: [String: String]
        let bundleIdentifier: String
        let appVersion: String
        let build: String
        let pid: Int32
        let logURL: URL
        let now: Date
        let fileManager: FileManager

        static func live() -> Configuration {
            let bundle = Bundle.main
            return Configuration(
                environment: ProcessInfo.processInfo.environment,
                bundleIdentifier: bundle.bundleIdentifier ?? "unknown",
                appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                pid: ProcessInfo.processInfo.processIdentifier,
                logURL: defaultLogURL(bundleIdentifier: bundle.bundleIdentifier ?? "unknown"),
                now: Date(),
                fileManager: .default
            )
        }
    }

    static func append(_ event: String, fields: [String: String] = [:]) {
        append(event, fields: fields, configuration: .live())
    }

    static func append(_ event: String, fields: [String: String] = [:], configuration: Configuration) {
        guard isEnabled(
            environment: configuration.environment,
            bundleIdentifier: configuration.bundleIdentifier
        ) else { return }

        var payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: configuration.now),
            "event": event,
            "pid": configuration.pid,
            "bundleIdentifier": configuration.bundleIdentifier,
            "appVersion": configuration.appVersion,
            "build": configuration.build
        ]

        for (key, value) in fields {
            let payloadKey = reservedFieldKeys.contains(key) ? "custom_\(key)" : key
            payload[payloadKey] = sanitized(value)
        }

        do {
            let url = configuration.logURL
            let fileManager = configuration.fileManager
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try rotateIfNeeded(at: url, fileManager: fileManager)
            if !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: nil)
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

    static func isEnabled(environment: [String: String], bundleIdentifier: String?) -> Bool {
        if environment["CMUX_DISABLE_STARTUP_BREADCRUMBS"] == "1" {
            return false
        }
        if environment["CMUX_STARTUP_BREADCRUMBS"] == "1" {
            return true
        }
        return !(bundleIdentifier ?? "").isEmpty
    }

    static var currentLogURL: URL {
        defaultLogURL(bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown")
    }

    static func tailContext(
        logURL: URL = currentLogURL,
        fileManager: FileManager = .default,
        maxLines: Int = maximumTailLines,
        maxBytes: Int = maximumTailBytes
    ) -> [String: Any]? {
        var lines: [String] = []
        for url in [rotatedLogURL(for: logURL), logURL] where fileManager.fileExists(atPath: url.path) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            lines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
        }
        guard !lines.isEmpty else { return nil }

        var selected = Array(lines.suffix(maxLines))
        var tail = selected.joined(separator: "\n")
        var truncated = lines.count > selected.count
        while tail.utf8.count > maxBytes, selected.count > 1 {
            selected.removeFirst()
            tail = selected.joined(separator: "\n")
            truncated = true
        }
        if tail.utf8.count > maxBytes {
            tail = String(decoding: tail.utf8.suffix(maxBytes), as: UTF8.self)
            truncated = true
        }

        return [
            "tail": tail,
            "line_count": selected.count,
            "truncated": truncated
        ]
    }

    /// Adds the bounded startup breadcrumb log tail to crash-shaped events.
    ///
    /// Call this before `SentryEventScrubber.scrub(_:)` so the attached log tail
    /// flows through the same path/email/secret redaction as every other context.
    static func attachTailIfCrash(
        to event: Event,
        logURL: URL = currentLogURL,
        fileManager: FileManager = .default
    ) -> Event {
        guard isCrashOrFatalEvent(event),
              let context = tailContext(logURL: logURL, fileManager: fileManager) else {
            return event
        }

        var contexts = event.context ?? [:]
        contexts["startup_log"] = context
        event.context = contexts
        return event
    }

    private static func defaultLogURL(bundleIdentifier: String) -> URL {
        let logsDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs/cmux", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("cmux-logs", isDirectory: true)
        let sanitizedBundleIdentifier = logFileComponent(bundleIdentifier)
        return logsDirectory.appendingPathComponent("startup-\(sanitizedBundleIdentifier).log")
    }

    static func rotatedLogURL(for url: URL) -> URL {
        URL(fileURLWithPath: url.path + ".1")
    }

    private static func rotateIfNeeded(at url: URL, fileManager: FileManager) throws {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue >= maximumLogBytes else {
            return
        }

        let rotatedURL = rotatedLogURL(for: url)
        if fileManager.fileExists(atPath: rotatedURL.path) {
            try fileManager.removeItem(at: rotatedURL)
        }
        try fileManager.moveItem(at: url, to: rotatedURL)
        fileManager.createFile(atPath: url.path, contents: nil)
    }

    private static func isCrashOrFatalEvent(_ event: Event) -> Bool {
        if event.level == .fatal {
            return true
        }

        return event.exceptions?.contains { exception in
            let type = (exception.type ?? "").uppercased()
            return type.hasPrefix("EXC_") ||
                type.hasPrefix("SIG") ||
                type == "NSRANGEEXCEPTION" ||
                type == "NSINVALIDARGUMENTEXCEPTION" ||
                type == "NSINTERNALINCONSISTENCYEXCEPTION"
        } ?? false
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

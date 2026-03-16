import AppKit
import Foundation

// MARK: - UpdateLogStore

final class UpdateLogStore {
    // MARK: Static Properties

    static let shared = UpdateLogStore()

    // MARK: Properties

    private let queue = DispatchQueue(label: "cmux.update.log")
    private var entries: [String] = []
    private let maxEntries = 200
    private let logURL: URL
    private let formatter: ISO8601DateFormatter

    // MARK: Lifecycle

    private init() {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        logURL = logsDir.appendingPathComponent("Logs/cmux-update.log")
        ensureLogFile()
    }

    // MARK: Functions

    func append(_ message: String) {
        let timestamp = formatter.string(from: Date())
        let bundle = Bundle.main.bundleIdentifier ?? "<no.bundle.id>"
        let pid = ProcessInfo.processInfo.processIdentifier
        let line = "[\(timestamp)] [\(bundle):\(pid)] \(message)"
        queue.async { [weak self] in
            guard let self else { return }
            entries.append(line)
            if entries.count > maxEntries {
                entries.removeFirst(entries.count - maxEntries)
            }
            appendToFile(line: line)
        }
    }

    func snapshot() -> String {
        queue.sync {
            entries.joined(separator: "\n")
        }
    }

    func logPath() -> String {
        logURL.path
    }

    private func ensureLogFile() {
        let directory = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try? Data().write(to: logURL)
        }
    }

    private func appendToFile(line: String) {
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }
}

// MARK: - FocusLogStore

final class FocusLogStore {
    // MARK: Static Properties

    static let shared = FocusLogStore()

    // MARK: Properties

    private let queue = DispatchQueue(label: "cmux.focus.log")
    private var entries: [String] = []
    private let maxEntries = 400
    private let logURL: URL
    private let formatter: ISO8601DateFormatter

    // MARK: Lifecycle

    private init() {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        logURL = logsDir.appendingPathComponent("Logs/cmux-focus.log")
        ensureLogFile()
    }

    // MARK: Functions

    func append(_ message: String) {
        #if DEBUG
            let timestamp = formatter.string(from: Date())
            let line = "[\(timestamp)] \(message)"
            queue.async { [weak self] in
                guard let self else { return }
                entries.append(line)
                if entries.count > maxEntries {
                    entries.removeFirst(entries.count - maxEntries)
                }
                appendToFile(line: line)
            }
        #endif
    }

    func snapshot() -> String {
        queue.sync {
            entries.joined(separator: "\n")
        }
    }

    func logPath() -> String {
        logURL.path
    }

    private func ensureLogFile() {
        let directory = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try? Data().write(to: logURL)
        }
    }

    private func appendToFile(line: String) {
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }
}

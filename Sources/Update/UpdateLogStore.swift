import Foundation
import AppKit

final class UpdateLogStore {
    static let shared = UpdateLogStore()

    private let queue = DispatchQueue(label: "cmux.update.log")
    private var entries: [String] = []
    private let maxEntries = 200
    private let maxFileSize: UInt64 = 256 * 1024 // 256 KB
    private let logURL: URL
    private let formatter: ISO8601DateFormatter

    private init() {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        logURL = logsDir.appendingPathComponent("Logs/cmux-update.log")
        ensureLogFile()
    }

    func append(_ message: String) {
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
            let fileSize = handle.seekToEndOfFile()
            if fileSize > maxFileSize {
                try? handle.close()
                truncateLogFile()
                if let h2 = try? FileHandle(forWritingTo: logURL) {
                    h2.seekToEndOfFile()
                    try? h2.write(contentsOf: data)
                    try? h2.close()
                }
            } else {
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    private func truncateLogFile() {
        guard let content = try? String(contentsOf: logURL, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: "\n")
        let keepCount = lines.count / 2
        let kept = lines.suffix(keepCount).joined(separator: "\n")
        try? kept.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

final class FocusLogStore {
    static let shared = FocusLogStore()

    private let queue = DispatchQueue(label: "cmux.focus.log")
    private var entries: [String] = []
    private let maxEntries = 400
    private let maxFileSize: UInt64 = 256 * 1024 // 256 KB
    private let logURL: URL
    private let formatter: ISO8601DateFormatter

    private init() {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        logURL = logsDir.appendingPathComponent("Logs/cmux-focus.log")
        ensureLogFile()
    }

    func append(_ message: String) {
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
            let fileSize = handle.seekToEndOfFile()
            if fileSize > maxFileSize {
                try? handle.close()
                truncateLogFile()
                if let h2 = try? FileHandle(forWritingTo: logURL) {
                    h2.seekToEndOfFile()
                    try? h2.write(contentsOf: data)
                    try? h2.close()
                }
            } else {
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    private func truncateLogFile() {
        guard let content = try? String(contentsOf: logURL, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: "\n")
        let keepCount = lines.count / 2
        let kept = lines.suffix(keepCount).joined(separator: "\n")
        try? kept.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

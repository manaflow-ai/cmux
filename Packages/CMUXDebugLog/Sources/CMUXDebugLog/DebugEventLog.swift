#if DEBUG
import Foundation

/// Ring-buffer event log used by cmux debug builds.
///
/// Every entry is appended to the resolved log file immediately so `tail -f`
/// shows live keyboard, focus, split, tab, and browser diagnostics.
public final class DebugEventLog: @unchecked Sendable {
    public static let shared = DebugEventLog()

    private var entries: [String] = []
    private let capacity = 500
    private let queue = DispatchQueue(label: "cmux.debug-event-log")
    private static let logPath = resolveLogPath()

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private init() {}

    public func log(_ message: String) {
        let date = Date()

        queue.async {
            let timestamp = Self.formatter.string(from: date)
            let entry = "\(timestamp) \(message)"

            if self.entries.count >= self.capacity {
                self.entries.removeFirst()
            }
            self.entries.append(entry)

            let line = entry + "\n"
            guard let data = line.data(using: .utf8) else { return }

            if let handle = FileHandle(forWritingAtPath: Self.logPath) {
                defer { try? handle.close() }
                guard (try? handle.seekToEnd()) != nil else { return }
                try? handle.write(contentsOf: data)
            } else {
                FileManager.default.createFile(atPath: Self.logPath, contents: data)
            }
        }
    }

    /// Writes the current buffer to disk, replacing the existing log file.
    public func dump() {
        queue.async {
            let content = self.entries.joined(separator: "\n") + "\n"
            try? content.write(toFile: Self.logPath, atomically: true, encoding: .utf8)
        }
    }

    public static func currentLogPath() -> String {
        logPath
    }

    private static func sanitizePathToken(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let unicode = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let sanitized = String(unicode).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return sanitized.isEmpty ? "debug" : sanitized
    }

    private static func resolveLogPath() -> String {
        let env = ProcessInfo.processInfo.environment

        if let explicit = env["CMUX_DEBUG_LOG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }

        if let tag = env["CMUX_TAG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tag.isEmpty {
            return "/tmp/cmux-debug-\(sanitizePathToken(tag)).log"
        }

        if let socketPath = env["CMUX_SOCKET_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !socketPath.isEmpty {
            let socketBase = URL(fileURLWithPath: socketPath).deletingPathExtension().lastPathComponent
            if socketBase.hasPrefix("cmux-debug-") {
                return "/tmp/\(socketBase).log"
            }
        }

        if let bundleId = Bundle.main.bundleIdentifier,
           bundleId != "com.cmuxterm.app.debug" {
            return "/tmp/cmux-debug-\(sanitizePathToken(bundleId)).log"
        }

        return "/tmp/cmux-debug.log"
    }
}

public func logDebugEvent(_ message: @autoclosure () -> String) {
    DebugEventLog.shared.log(message())
}
#endif

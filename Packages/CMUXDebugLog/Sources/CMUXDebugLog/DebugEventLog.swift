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
    private static let debugFieldPattern = try! NSRegularExpression(
        pattern: "(^| )([A-Za-z][A-Za-z0-9_-]*)=",
        options: []
    )
    private static let knownDebugFieldNames: Set<String> = [
        "action",
        "actual",
        "authorization",
        "available",
        "body",
        "button",
        "buttonnumber",
        "bytes",
        "cangoback",
        "cangoforward",
        "canpaste",
        "clicks",
        "closed",
        "command",
        "contenteditable",
        "count",
        "cookie",
        "cookies",
        "cwd",
        "defaultname",
        "delayms",
        "dest",
        "destination",
        "depth",
        "dir",
        "directory",
        "dispatched",
        "downloading",
        "error",
        "eventtype",
        "expected",
        "fallbackimageurl",
        "fallbacklinkurl",
        "fallbacktodataurl",
        "fallbacktoweakcandidate",
        "file",
        "filename",
        "format",
        "fr",
        "handled",
        "hasresponse",
        "header",
        "id",
        "imageurl",
        "imgurl",
        "index",
        "initialinput",
        "input",
        "itemcount",
        "kind",
        "length",
        "linkurl",
        "mediaurl",
        "method",
        "mime",
        "mods",
        "needle",
        "nearestanchorurl",
        "normalized",
        "normalizedfallbacklinkurl",
        "normalizedimageurl",
        "normalizedlinkurl",
        "normalizednearestanchorurl",
        "path",
        "payload",
        "point",
        "pointerdepth",
        "policy",
        "query",
        "reason",
        "referer",
        "rejectedprimaryimageurl",
        "result",
        "route",
        "routednative",
        "scheme",
        "shown",
        "skipped",
        "stage",
        "startupcommand",
        "status",
        "stderr",
        "stdout",
        "target",
        "text",
        "title",
        "token",
        "trace",
        "types",
        "uaset",
        "url",
        "urllength",
        "weakcandidateurl",
        "web",
        "win",
        "workspace",
        "wrote",
    ]

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private init() {}

    public func log(_ message: String) {
        let date = Date()
        let redactedMessage = Self.redactedDebugMessage(message)

        queue.async {
            let timestamp = Self.formatter.string(from: date)
            let entry = "\(timestamp) \(redactedMessage)"

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
        queue.sync {
            let content = self.entries.joined(separator: "\n") + "\n"
            try? content.write(toFile: Self.logPath, atomically: true, encoding: .utf8)
        }
    }

    public static func currentLogPath() -> String {
        logPath
    }

    static func redactedDebugMessage(_ message: String) -> String {
        let nsMessage = message as NSString
        let fullRange = NSRange(location: 0, length: nsMessage.length)
        let matches = debugFieldPattern.matches(in: message, range: fullRange)
        guard !matches.isEmpty else { return message }

        var result = ""
        var cursor = 0
        var matchIndex = 0

        while matchIndex < matches.count {
            let match = matches[matchIndex]
            let fieldStart = match.range.location
            if cursor < fieldStart {
                result += nsMessage.substring(
                    with: NSRange(location: cursor, length: fieldStart - cursor)
                )
            }

            let separatorRange = match.range(at: 1)
            if separatorRange.length > 0 {
                result += " "
            }

            let keyRange = match.range(at: 2)
            let key = nsMessage.substring(with: keyRange)
            let normalizedKey = key.lowercased()
            let valueStart = match.range.location + match.range.length
            let sensitive = shouldRedactDebugField(normalizedKey)
            let nextMatchIndex = sensitive
                ? nextKnownDebugFieldIndex(after: matchIndex, in: matches, message: nsMessage)
                : nextDebugFieldIndex(after: matchIndex, in: matches)
            let valueEnd: Int

            if sensitive && shouldConsumeRestOfDebugMessage(normalizedKey) {
                valueEnd = nsMessage.length
                matchIndex = matches.count
            } else {
                valueEnd = nextMatchIndex.map { matches[$0].range.location } ?? nsMessage.length
                matchIndex = nextMatchIndex ?? matches.count
            }

            let valueLength = max(0, valueEnd - valueStart)
            let value = nsMessage.substring(with: NSRange(location: valueStart, length: valueLength))

            if sensitive {
                result += "\(key)=\(redactedDebugValue(key: normalizedKey, value: value))"
            } else {
                result += nsMessage.substring(
                    with: NSRange(location: keyRange.location, length: valueEnd - keyRange.location)
                )
            }

            cursor = valueEnd
        }

        if cursor < nsMessage.length {
            result += nsMessage.substring(
                with: NSRange(location: cursor, length: nsMessage.length - cursor)
            )
        }

        return result
    }

    private static func nextDebugFieldIndex(
        after index: Int,
        in matches: [NSTextCheckingResult]
    ) -> Int? {
        let nextIndex = index + 1
        return nextIndex < matches.count ? nextIndex : nil
    }

    private static func nextKnownDebugFieldIndex(
        after index: Int,
        in matches: [NSTextCheckingResult],
        message: NSString
    ) -> Int? {
        var nextIndex = index + 1
        while nextIndex < matches.count {
            let key = message.substring(with: matches[nextIndex].range(at: 2)).lowercased()
            if knownDebugFieldNames.contains(key) || shouldRedactDebugField(key) {
                return nextIndex
            }
            nextIndex += 1
        }
        return nil
    }

    private static func shouldRedactDebugField(_ normalizedKey: String) -> Bool {
        normalizedKey == "authorization" ||
            normalizedKey == "body" ||
            normalizedKey == "command" ||
            normalizedKey == "cookie" ||
            normalizedKey == "cookies" ||
            normalizedKey == "cwd" ||
            normalizedKey == "dest" ||
            normalizedKey == "destination" ||
            normalizedKey == "dir" ||
            normalizedKey == "directory" ||
            normalizedKey == "exec" ||
            normalizedKey == "file" ||
            normalizedKey == "filename" ||
            normalizedKey == "header" ||
            normalizedKey == "initialinput" ||
            normalizedKey == "input" ||
            normalizedKey == "local" ||
            normalizedKey == "manifest" ||
            normalizedKey == "needle" ||
            normalizedKey == "normalized" ||
            normalizedKey == "path" ||
            normalizedKey == "payload" ||
            normalizedKey == "query" ||
            normalizedKey == "referer" ||
            normalizedKey == "remote" ||
            normalizedKey == "remotetemp" ||
            normalizedKey == "stderr" ||
            normalizedKey == "stdout" ||
            normalizedKey == "startupcommand" ||
            normalizedKey == "text" ||
            normalizedKey == "title" ||
            normalizedKey == "token" ||
            normalizedKey == "url" ||
            normalizedKey.contains("authorization") ||
            normalizedKey.contains("cookie") ||
            normalizedKey.contains("credential") ||
            normalizedKey.contains("filename") ||
            normalizedKey.contains("token") ||
            normalizedKey.hasSuffix("args") ||
            normalizedKey.hasSuffix("command") ||
            normalizedKey.hasSuffix("dir") ||
            normalizedKey.hasSuffix("file") ||
            normalizedKey.hasSuffix("header") ||
            normalizedKey.hasSuffix("input") ||
            normalizedKey.hasSuffix("path") ||
            normalizedKey.hasSuffix("socket") ||
            normalizedKey.hasSuffix("text") ||
            normalizedKey.hasSuffix("url")
    }

    private static func shouldConsumeRestOfDebugMessage(_ normalizedKey: String) -> Bool {
        normalizedKey == "body" ||
            normalizedKey == "exec" ||
            normalizedKey == "input" ||
            normalizedKey == "needle" ||
            normalizedKey == "normalized" ||
            normalizedKey == "payload" ||
            normalizedKey == "query" ||
            normalizedKey == "stderr" ||
            normalizedKey == "stdout" ||
            normalizedKey == "text" ||
            normalizedKey.hasSuffix("args") ||
            normalizedKey.hasSuffix("command")
    }

    private static func redactedDebugValue(key: String, value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "nil", trimmed != "(nil)" else { return value }

        if shouldTreatDebugFieldAsURL(key) {
            let candidate = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if let url = URL(string: candidate),
               let scheme = url.scheme?.lowercased(),
               !scheme.isEmpty {
                switch scheme {
                case "http", "https":
                    return "\(scheme)://\(url.host ?? "unknown")"
                case "data":
                    return "data:<redacted>"
                case "file":
                    return "file:<redacted>"
                default:
                    return "\(scheme):<redacted>"
                }
            }
        }

        return "<redacted:\(value.utf8.count)b>"
    }

    private static func shouldTreatDebugFieldAsURL(_ normalizedKey: String) -> Bool {
        normalizedKey == "referer" || normalizedKey.hasSuffix("url")
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

import Foundation

public struct GrokSessionSummary: Equatable, Sendable {
    public let title: String?
    public let lastAssistantMessage: String?

    public init(title: String?, lastAssistantMessage: String?) {
        self.title = title
        self.lastAssistantMessage = lastAssistantMessage
    }
}

public struct GrokSessionSummaryReader: Sendable {
    private let grokHome: URL

    public init(
        grokHome: URL? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.grokHome = grokHome ?? Self.grokHomeURL(env: env)
    }

    public func summary(sessionId: String, cwd: String?) -> GrokSessionSummary? {
        guard let sessionDirectory = sessionDirectory(sessionId: sessionId, cwd: cwd) else {
            return nil
        }
        return summary(in: sessionDirectory)
    }

    public func latestSummary(cwd: String?) -> GrokSessionSummary? {
        guard let sessionDirectory = latestSessionDirectory(cwd: cwd) else {
            return nil
        }
        return summary(in: sessionDirectory)
    }

    public func sessionDirectory(sessionId: String, cwd: String?) -> URL? {
        let trimmedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionId.isEmpty,
              !trimmedSessionId.contains("/"),
              !trimmedSessionId.contains("\0"),
              !trimmedSessionId.contains("..")
        else { return nil }

        let sessionsRoot = grokHome.appendingPathComponent("sessions", isDirectory: true)
        if let cwd, !cwd.isEmpty {
            let expandedCWD = NSString(string: cwd).expandingTildeInPath
            let candidate = sessionsRoot
                .appendingPathComponent(Self.encodedSessionCWD(expandedCWD), isDirectory: true)
                .appendingPathComponent(trimmedSessionId, isDirectory: true)
            return directoryExists(candidate) ? candidate : nil
        }

        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for project in projects where directoryExists(project) {
            let candidate = project.appendingPathComponent(trimmedSessionId, isDirectory: true)
            if directoryExists(candidate) {
                return candidate
            }
        }
        return nil
    }

    public func latestSessionDirectory(cwd: String?) -> URL? {
        let sessionsRoot = grokHome.appendingPathComponent("sessions", isDirectory: true)
        if let cwd, !cwd.isEmpty {
            let expandedCWD = NSString(string: cwd).expandingTildeInPath
            let projectDirectory = sessionsRoot
                .appendingPathComponent(Self.encodedSessionCWD(expandedCWD), isDirectory: true)
            return newestSessionDirectory(in: projectDirectory)
        }

        guard let projectDirectories = try? FileManager.default.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return projectDirectories
            .compactMap { newestSessionDirectory(in: $0) }
            .max { sessionSortDate($0) < sessionSortDate($1) }
    }

    public static func encodedSessionCWD(_ cwd: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return cwd.addingPercentEncoding(withAllowedCharacters: allowed) ?? cwd
    }

    private static func grokHomeURL(env: [String: String]) -> URL {
        if let grokHome = normalizedEnvValue(env["GROK_HOME"]) {
            return URL(fileURLWithPath: NSString(string: grokHome).expandingTildeInPath, isDirectory: true)
        }
        if let home = normalizedEnvValue(env["HOME"]) {
            return URL(fileURLWithPath: NSString(string: home).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent(".grok", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
    }

    private static func normalizedEnvValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func summary(in sessionDirectory: URL) -> GrokSessionSummary? {
        let title = sessionTitle(
            at: sessionDirectory.appendingPathComponent("summary.json", isDirectory: false)
        )
        let assistantMessage = lastAssistantMessage(
            at: sessionDirectory.appendingPathComponent("chat_history.jsonl", isDirectory: false)
        )

        guard title != nil || assistantMessage != nil else { return nil }
        return GrokSessionSummary(title: title, lastAssistantMessage: assistantMessage)
    }

    private func newestSessionDirectory(in projectDirectory: URL) -> URL? {
        guard directoryExists(projectDirectory),
              let sessionDirectories = try? FileManager.default.contentsOfDirectory(
                at: projectDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              )
        else { return nil }

        return sessionDirectories
            .filter { directoryExists($0) }
            .max { sessionSortDate($0) < sessionSortDate($1) }
    }

    private func directoryExists(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func sessionSortDate(_ sessionDirectory: URL) -> Date {
        let candidates = [
            sessionDirectory.appendingPathComponent("chat_history.jsonl", isDirectory: false),
            sessionDirectory.appendingPathComponent("summary.json", isDirectory: false),
            sessionDirectory,
        ]
        return candidates
            .compactMap {
                try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
            .max()
            ?? .distantPast
    }

    private func sessionTitle(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return firstString(in: object, keys: ["session_summary", "generated_title"])
    }

    private func lastAssistantMessage(at url: URL) -> String? {
        guard let content = tailString(at: url, maxBytes: 128 * 1024) else { return nil }

        var lastAssistantMessage: String?
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let text = assistantText(from: object)
            else { continue }
            lastAssistantMessage = text
        }
        return lastAssistantMessage
    }

    private func tailString(at url: URL, maxBytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > maxBytes ? size - maxBytes : 0
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private func assistantText(from object: [String: Any]) -> String? {
        if let text = object["content"] as? String {
            let normalized = normalizedSingleLine(text)
            return normalized.isEmpty ? nil : normalized
        }
        if let blocks = object["content"] as? [[String: Any]] {
            let text = blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text",
                      let text = block["text"] as? String else { return nil }
                let normalized = normalizedSingleLine(text)
                return normalized.isEmpty ? nil : normalized
            }
            .joined(separator: " ")
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] as? String else { continue }
            let normalized = normalizedSingleLine(value)
            if !normalized.isEmpty {
                return normalized
            }
        }
        return nil
    }

    private func normalizedSingleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

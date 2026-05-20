import Foundation

extension SessionIndexStore {
    private struct RegisteredAgentJSONLMetadata {
        var title: String = ""
        var cwd: String?
        var branch: String?
        var sessionId: String?
    }

    private struct AntigravityHistoryMetadata {
        let sessionId: String
        let title: String
        let cwd: String?
        let modified: Date
        let fileURL: URL
    }

    nonisolated static func loadRegisteredAgentEntries(
        registration: CmuxVaultAgentRegistration,
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int
    ) async -> [SessionEntry] {
        if registration.id == CmuxVaultAgentRegistration.builtInAntigravity.id {
            return loadAntigravityHistoryEntries(
                registration: registration,
                needle: needle,
                cwdFilter: cwdFilter,
                offset: offset,
                limit: limit
            )
        }

        let roots = registeredSessionRoots(registration: registration, cwdFilter: cwdFilter)
        guard !roots.isEmpty else { return [] }
        let fm = FileManager.default

        var candidates: [(url: URL, modified: Date, prefilteredByRipgrep: Bool)] = []
        if !needle.isEmpty {
            for root in roots {
                guard let rgPaths = await ripgrepMatchingPaths(needle: needle, root: root, fileGlob: "*.jsonl") else {
                    candidates.append(
                        contentsOf: enumerateRegisteredJSONLCandidates(root: root).map {
                            (url: $0.0, modified: $0.1, prefilteredByRipgrep: false)
                        }
                    )
                    continue
                }
                for url in rgPaths {
                    guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                          let modified = attrs[.modificationDate] as? Date else {
                        continue
                    }
                    candidates.append((url, modified, true))
                }
            }
        } else {
            for root in roots {
                candidates.append(
                    contentsOf: enumerateRegisteredJSONLCandidates(root: root).map {
                        (url: $0.0, modified: $0.1, prefilteredByRipgrep: false)
                    }
                )
            }
        }

        candidates.sort { $0.modified > $1.modified }
        let target = offset + limit
        var matches: [SessionEntry] = []
        var scanned = 0
        for candidate in candidates {
            if Task.isCancelled { break }
            if matches.count >= target { break }
            if scanned >= searchMaxFiles { break }
            scanned += 1

            if !needle.isEmpty && !candidate.prefilteredByRipgrep {
                guard fileContains(candidate.url, needle: needle) else { continue }
            }

            let metadata = extractRegisteredJSONLMetadata(
                url: candidate.url,
                registration: registration,
                fallbackCWD: cwdFilter
            )
            if let cwdFilter, metadata.cwd != cwdFilter { continue }
            let sessionId = metadata.sessionId ?? candidate.url.path
            matches.append(SessionEntry(
                id: "\(registration.id):\(sessionId)",
                agent: .registered(RegisteredSessionAgent(registration: registration)),
                sessionId: sessionId,
                title: metadata.title,
                cwd: metadata.cwd,
                gitBranch: metadata.branch,
                pullRequest: nil,
                modified: candidate.modified,
                fileURL: candidate.url,
                specifics: .registered(registration)
            ))
        }
        return Array(matches.dropFirst(offset).prefix(limit))
    }

    nonisolated private static func loadAntigravityHistoryEntries(
        registration: CmuxVaultAgentRegistration,
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int
    ) -> [SessionEntry] {
        let roots = registeredSessionRoots(registration: registration, cwdFilter: cwdFilter)
        guard !roots.isEmpty else { return [] }

        let fm = FileManager.default
        var latestBySessionID: [String: AntigravityHistoryMetadata] = [:]

        for root in roots {
            if Task.isCancelled { break }
            let historyURL = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent("history.jsonl", isDirectory: false)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: historyURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }
            let fallbackModified = ((try? fm.attributesOfItem(atPath: historyURL.path))?[.modificationDate] as? Date)
                ?? Date.distantPast

            forEachJSONLine(url: historyURL, maxBytes: Int.max) { object in
                if Task.isCancelled { return true }
                guard let sessionId = firstString(in: object, keys: antigravitySessionIDKeys()) else {
                    return false
                }
                let cwd = firstString(in: object, keys: registeredJSONLCWDKeys())
                if let cwdFilter, cwd != cwdFilter { return false }

                let title = firstTopLevelTitle(in: object) ?? ""
                guard antigravityHistoryMatchesNeedle(
                    needle: needle,
                    sessionId: sessionId,
                    title: title,
                    cwd: cwd
                ) else {
                    return false
                }

                let modified = antigravityHistoryModifiedDate(in: object, fallback: fallbackModified)
                let metadata = AntigravityHistoryMetadata(
                    sessionId: sessionId,
                    title: title,
                    cwd: cwd,
                    modified: modified,
                    fileURL: historyURL
                )
                if let existing = latestBySessionID[sessionId] {
                    if metadata.modified >= existing.modified {
                        latestBySessionID[sessionId] = metadata
                    }
                } else {
                    latestBySessionID[sessionId] = metadata
                }
                return false
            }
        }

        let entries = latestBySessionID.values
            .sorted {
                if $0.modified == $1.modified {
                    return $0.sessionId < $1.sessionId
                }
                return $0.modified > $1.modified
            }
            .map { metadata in
                SessionEntry(
                    id: "\(registration.id):\(metadata.sessionId)",
                    agent: .registered(RegisteredSessionAgent(registration: registration)),
                    sessionId: metadata.sessionId,
                    title: metadata.title,
                    cwd: metadata.cwd,
                    gitBranch: nil,
                    pullRequest: nil,
                    modified: metadata.modified,
                    fileURL: metadata.fileURL,
                    specifics: .registered(registration)
                )
            }
        return Array(entries.dropFirst(offset).prefix(limit))
    }

    nonisolated private static func registeredSessionRoots(
        registration: CmuxVaultAgentRegistration,
        cwdFilter: String?
    ) -> [String] {
        guard let root = registration.sessionDirectory.map({ ($0 as NSString).expandingTildeInPath }) else {
            return []
        }
        if case .piSessionFile = registration.sessionIdSource,
           let cwdFilter,
           let projectDirectory = PiSessionLocator.projectDirectoryName(for: cwdFilter) {
            return [(root as NSString).appendingPathComponent(projectDirectory)]
        }
        return [root]
    }

    nonisolated private static func enumerateRegisteredJSONLCandidates(root: String) -> [(URL, Date)] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = fm.enumerator(
                  at: URL(fileURLWithPath: root, isDirectory: true),
                  includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        var candidates: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate else { continue }
            candidates.append((url, modified))
        }
        return candidates
    }

    nonisolated private static func extractRegisteredJSONLMetadata(
        url: URL,
        registration: CmuxVaultAgentRegistration,
        fallbackCWD: String?
    ) -> RegisteredAgentJSONLMetadata {
        var metadata = RegisteredAgentJSONLMetadata()
        let needsNativeSessionID: Bool
        switch registration.sessionIdSource {
        case .argvOption:
            needsNativeSessionID = true
        case .piSessionFile:
            needsNativeSessionID = false
        }
        forEachJSONLine(url: url, maxBytes: 512 * 1024) { object in
            if metadata.sessionId == nil {
                metadata.sessionId = firstString(in: object, keys: antigravitySessionIDKeys())
            }
            if metadata.cwd == nil {
                metadata.cwd = firstString(in: object, keys: registeredJSONLCWDKeys())
            }
            if metadata.branch == nil, let git = object["git"] as? [String: Any] {
                metadata.branch = firstString(in: git, keys: ["branch", "gitBranch"])
            }
            if metadata.branch == nil {
                metadata.branch = firstString(in: object, keys: ["gitBranch", "branch"])
            }
            if metadata.title.isEmpty {
                metadata.title = firstTopLevelTitle(in: object) ?? ""
            }
            if metadata.title.isEmpty, let message = object["message"] as? [String: Any] {
                if shouldUseMessageAsTitle(message) {
                    metadata.title = firstText(in: message, keys: ["content", "text"]) ?? ""
                }
            }
            if metadata.title.isEmpty, let messages = object["messages"] as? [[String: Any]] {
                metadata.title = messages.compactMap { message in
                    shouldUseMessageAsTitle(message)
                        ? firstText(in: message, keys: ["content", "text"])
                        : nil
                }.first ?? ""
            }
            return !metadata.title.isEmpty
                && metadata.cwd != nil
                && metadata.branch != nil
                && (!needsNativeSessionID || metadata.sessionId != nil)
        }
        if case .piSessionFile = registration.sessionIdSource, metadata.cwd == nil {
            metadata.cwd = fallbackCWD ?? piCWDInferred(from: url)
        }
        return metadata
    }

    nonisolated private static func registeredJSONLCWDKeys() -> [String] {
        ["cwd", "workingDirectory", "workspacePath", "workspace", "projectPath", "directory"]
    }

    nonisolated private static func antigravitySessionIDKeys() -> [String] {
        ["conversationId", "conversation_id", "sessionId", "session_id", "id"]
    }

    nonisolated private static func antigravityHistoryMatchesNeedle(
        needle: String,
        sessionId: String,
        title: String,
        cwd: String?
    ) -> Bool {
        guard !needle.isEmpty else { return true }
        return [sessionId, title, cwd ?? ""].contains { value in
            value.range(of: needle, options: [.caseInsensitive, .literal]) != nil
        }
    }

    nonisolated private static func antigravityHistoryModifiedDate(
        in object: [String: Any],
        fallback: Date
    ) -> Date {
        guard let timestamp = antigravityNumericTimestamp(object["timestamp"]) else {
            return fallback
        }
        let seconds = timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp
        guard seconds.isFinite, seconds > 0 else { return fallback }
        return Date(timeIntervalSince1970: seconds)
    }

    nonisolated private static func antigravityNumericTimestamp(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    nonisolated private static func fileContains(_ url: URL, needle: String) -> Bool {
        guard !needle.isEmpty,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }

        let chunkSize = 64 * 1024
        let overlapLimit = max(needle.utf8.count * 4, 4 * 1024)
        var carry = Data()
        while !Task.isCancelled {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty { break }

            var buffer = carry
            buffer.append(chunk)
            let text = String(decoding: buffer, as: UTF8.self)
            if text.range(of: needle, options: [.caseInsensitive, .literal]) != nil {
                return true
            }
            carry = buffer.count > overlapLimit ? Data(buffer.suffix(overlapLimit)) : buffer
        }
        return false
    }

    nonisolated private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    nonisolated private static func firstText(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let text = firstTextValue(object[key]) else { continue }
            return text
        }
        return nil
    }

    nonisolated private static func firstTopLevelTitle(in object: [String: Any]) -> String? {
        if let title = firstText(in: object, keys: ["title", "prompt", "display"]) {
            return title
        }
        guard shouldUseMessageAsTitle(object) else { return nil }
        return firstText(in: object, keys: ["text", "content"])
    }

    nonisolated private static func firstTextValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return trimmedNonEmpty(string)
        }
        if let values = value as? [Any] {
            for value in values {
                if let text = firstTextBlock(value) {
                    return text
                }
            }
        }
        if let block = value as? [String: Any] {
            return firstTextBlock(block)
        }
        return nil
    }

    nonisolated private static func firstTextBlock(_ value: Any) -> String? {
        if let string = value as? String {
            return trimmedNonEmpty(string)
        }
        guard let block = value as? [String: Any] else { return nil }
        guard let type = firstString(in: block, keys: ["type"]),
              type.caseInsensitiveCompare("text") == .orderedSame else {
            return nil
        }
        return firstString(in: block, keys: ["text"])
    }

    nonisolated private static func trimmedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func shouldUseMessageAsTitle(_ message: [String: Any]) -> Bool {
        let role = firstString(in: message, keys: ["role"])
        return role == nil || isUserRole(role)
    }

    nonisolated private static func isUserRole(_ role: String?) -> Bool {
        role?.caseInsensitiveCompare("user") == .orderedSame
    }

    nonisolated private static func piCWDInferred(from url: URL) -> String? {
        let directoryName = url.deletingLastPathComponent().lastPathComponent
        guard directoryName.hasPrefix("--"), directoryName.hasSuffix("--"), directoryName.count > 4 else {
            return nil
        }
        let body = String(directoryName.dropFirst(2).dropLast(2))
        guard !body.isEmpty else { return nil }
        let candidate = "/" + body.replacingOccurrences(of: "-", with: "/")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return candidate
    }
}

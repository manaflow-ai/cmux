import Foundation

public enum RovoDevSessionResolver {
    private struct RovoDevSessionCandidate {
        let sessionId: String
        let modified: Date
    }

    public static func inferredRovoDevSessionId(cwd: String?, env: [String: String]) -> String? {
        let sessionsRoot = rovoDevSessionsRoot(env: env)
        let rootURL = URL(fileURLWithPath: sessionsRoot, isDirectory: true)
        let fileManager = FileManager.default
        guard let sessionURLs = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let normalizedCwd = RovoDevIndex.normalizedPath(cwd)
        var candidates: [RovoDevSessionCandidate] = []
        candidates.reserveCapacity(sessionURLs.count)
        for sessionURL in sessionURLs {
            guard (try? sessionURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let metadataURL = sessionURL.appendingPathComponent("metadata.json", isDirectory: false)
            guard let data = try? Data(contentsOf: metadataURL),
                  let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let workspace = RovoDevMetadataFields.workspacePath(from: metadata)
            let normalizedWorkspace = RovoDevIndex.normalizedPath(workspace)
            guard rovoDevWorkspace(normalizedWorkspace, matches: normalizedCwd) else {
                continue
            }
            let sessionContextURL = sessionURL.appendingPathComponent("session_context.json", isDirectory: false)
            let modified = max(
                RovoDevIndex.contentModificationDate(ofRegularFile: metadataURL) ?? Date.distantPast,
                RovoDevIndex.contentModificationDate(ofRegularFile: sessionContextURL) ?? Date.distantPast
            )
            candidates.append(RovoDevSessionCandidate(
                sessionId: sessionURL.lastPathComponent,
                modified: modified
            ))
        }
        candidates.sort {
            if $0.modified == $1.modified {
                // Rovo session IDs are time-ordered, so descending sessionId
                // keeps equal modified times stable while preferring newer sessions.
                return $0.sessionId > $1.sessionId
            }
            return $0.modified > $1.modified
        }
        return candidates.first?.sessionId
    }

    public static func rovoDevSessionsRoot(env: [String: String]) -> String {
        if let override = normalizedHookValue(env["CMUX_ROVODEV_SESSIONS_DIR"]) {
            return rovoDevExpandedPath(override, env: env)
        }
        let configPath = (rovoDevHomeDirectory(env: env) as NSString)
            .appendingPathComponent(".rovodev/config.yml")
        let configURL = URL(fileURLWithPath: configPath, isDirectory: false)
        guard let config = try? String(contentsOf: configURL, encoding: .utf8),
              let persistenceDir = rovoDevPersistenceDir(fromConfig: config) else {
            return (rovoDevHomeDirectory(env: env) as NSString)
                .appendingPathComponent(".rovodev/sessions")
        }
        return rovoDevExpandedPath(persistenceDir, env: env)
    }

    private static func rovoDevWorkspace(_ workspace: String?, matches cwd: String?) -> Bool {
        guard let cwd, !cwd.isEmpty else { return false }
        guard let workspace, !workspace.isEmpty else { return false }
        return cwd == workspace
    }

    public static func rovoDevPersistenceDir(fromConfig config: String) -> String? {
        let lines = normalizedYAMLLines(config)
        guard let sessionsIndex = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return leadingWhitespaceCount(line) == 0
                && trimmed.range(of: #"^sessions:\s*(#.*)?$"#, options: .regularExpression) != nil
        }) else {
            return nil
        }
        let sessionsIndent = leadingWhitespaceCount(lines[sessionsIndex])
        var directChildIndent: Int?
        for index in (sessionsIndex + 1)..<lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            let indent = leadingWhitespaceCount(line)
            if indent <= sessionsIndent {
                break
            }
            if directChildIndent == nil {
                directChildIndent = indent
            }
            guard indent == directChildIndent,
                  trimmed.hasPrefix("persistenceDir:") else {
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else {
                continue
            }
            let rawValue = String(trimmed[trimmed.index(after: colon)...])
            let value = rovoDevYAMLScalar(rawValue)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func normalizedHookValue(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func rovoDevHomeDirectory(env: [String: String]) -> String {
        normalizedHookValue(env["HOME"]) ?? NSHomeDirectory()
    }

    private static func rovoDevExpandedPath(_ path: String, env: [String: String]) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "~" || trimmed.hasPrefix("~/") else {
            return NSString(string: trimmed).expandingTildeInPath
        }
        let home = rovoDevHomeDirectory(env: env)
        guard trimmed != "~" else { return home }
        return (home as NSString).appendingPathComponent(String(trimmed.dropFirst(2)))
    }

    private static func normalizedYAMLLines(_ config: String) -> [String] {
        config
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func leadingWhitespaceCount(_ value: String) -> Int {
        value.prefix { $0 == " " || $0 == "\t" }.count
    }

    private static func rovoDevYAMLScalar(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        if value.first == "'" {
            value.removeFirst()
            var parsed = ""
            var index = value.startIndex
            while index < value.endIndex {
                let character = value[index]
                if character == "'" {
                    let next = value.index(after: index)
                    if next < value.endIndex, value[next] == "'" {
                        parsed.append("'")
                        index = value.index(after: next)
                        continue
                    }
                    return parsed
                }
                parsed.append(character)
                index = value.index(after: index)
            }
            return parsed
        }
        if value.first == "\"" {
            value.removeFirst()
            var parsed = ""
            var index = value.startIndex
            while index < value.endIndex {
                let character = value[index]
                if character == "\"" {
                    return parsed
                }
                if character == "\\" {
                    let next = value.index(after: index)
                    guard next < value.endIndex else { break }
                    parsed.append(decodedYAMLEscape(value[next]))
                    index = value.index(after: next)
                    continue
                }
                parsed.append(character)
                index = value.index(after: index)
            }
            return parsed
        }
        if let comment = value.firstIndex(of: "#"),
           comment > value.startIndex,
           value[value.index(before: comment)].isWhitespace {
            value = String(value[..<comment])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodedYAMLEscape(_ character: Character) -> Character {
        switch character {
        case "n": return "\n"
        case "r": return "\r"
        case "t": return "\t"
        default: return character
        }
    }
}

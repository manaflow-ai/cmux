import Foundation

extension SessionIndexStore {
    private struct RegisteredAgentJSONLMetadata {
        var title: String = ""
        var cwd: String?
        var branch: String?
    }

    nonisolated static func loadRegisteredAgentEntries(
        registration: CmuxVaultAgentRegistration,
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int
    ) async -> [SessionEntry] {
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
                let combined = readFileHead(url: candidate.url, byteCap: headByteCap)
                    + "\n"
                    + readFileTail(url: candidate.url, byteCap: tailByteCap)
                guard combined.range(of: needle, options: [.caseInsensitive, .literal]) != nil else { continue }
            }

            let metadata = extractRegisteredJSONLMetadata(
                url: candidate.url,
                registration: registration,
                fallbackCWD: cwdFilter
            )
            if let cwdFilter, metadata.cwd != cwdFilter { continue }
            matches.append(SessionEntry(
                id: "\(registration.id):\(candidate.url.path)",
                agent: .registered(RegisteredSessionAgent(registration: registration)),
                sessionId: candidate.url.path,
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
        metadata.cwd = fallbackCWD
        forEachJSONLine(url: url, maxBytes: 512 * 1024) { object in
            if metadata.cwd == nil {
                metadata.cwd = firstString(
                    in: object,
                    keys: ["cwd", "workingDirectory", "workspacePath", "projectPath", "directory"]
                )
            }
            if metadata.branch == nil, let git = object["git"] as? [String: Any] {
                metadata.branch = firstString(in: git, keys: ["branch", "gitBranch"])
            }
            if metadata.branch == nil {
                metadata.branch = firstString(in: object, keys: ["gitBranch", "branch"])
            }
            if metadata.title.isEmpty {
                metadata.title = firstString(in: object, keys: ["title", "prompt", "text", "content"]) ?? ""
            }
            if metadata.title.isEmpty, let message = object["message"] as? [String: Any] {
                metadata.title = firstString(in: message, keys: ["content", "text"]) ?? ""
            }
            if metadata.title.isEmpty, let messages = object["messages"] as? [[String: Any]] {
                metadata.title = messages.compactMap { message in
                    firstString(in: message, keys: ["role"]) == "user"
                        ? firstString(in: message, keys: ["content", "text"])
                        : nil
                }.first ?? ""
            }
            return !metadata.title.isEmpty && metadata.cwd != nil && metadata.branch != nil
        }
        if case .piSessionFile = registration.sessionIdSource, metadata.cwd == nil {
            metadata.cwd = piCWDInferred(from: url)
        }
        return metadata
    }

    nonisolated private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
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

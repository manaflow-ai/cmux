import Foundation

public struct RovoDevIndexedSession: Equatable, Sendable {
    public let sessionId: String
    public let title: String
    public let workspacePath: String?
    public let modified: Date
    public let sessionContextURL: URL?

    public init(
        sessionId: String,
        title: String,
        workspacePath: String?,
        modified: Date,
        sessionContextURL: URL?
    ) {
        self.sessionId = sessionId
        self.title = title
        self.workspacePath = workspacePath
        self.modified = modified
        self.sessionContextURL = sessionContextURL
    }
}

public struct RovoDevIndexResult: Equatable, Sendable {
    public let sessions: [RovoDevIndexedSession]
    public let errors: [String]

    public init(sessions: [RovoDevIndexedSession], errors: [String]) {
        self.sessions = sessions
        self.errors = errors
    }
}

public enum RovoDevMetadataFields {
    public static let titleKeys: [String] = [
        "title",
        "name",
        "summary",
    ]

    public static let workspacePathKeys: [String] = [
        "workspace_path",
        "workspacePath",
        "workspace",
        "cwd",
        "working_directory",
        "workingDirectory",
        "project_path",
        "projectPath",
    ]

    public static func title(from metadata: [String: Any]) -> String? {
        firstString(from: metadata, keys: titleKeys)
    }

    public static func workspacePath(from metadata: [String: Any]) -> String? {
        firstString(from: metadata, keys: workspacePathKeys)
    }

    public static func firstString(from metadata: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = metadata[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}

private enum RovoDevMetadataError: LocalizedError {
    case notObject

    var errorDescription: String? {
        switch self {
        case .notObject:
            return "metadata is not a JSON object"
        }
    }
}

private struct RovoDevSessionCandidate: Sendable {
    let sessionId: String
    let metadataURL: URL
    let sessionContextURL: URL
    let mtime: Date
}

public enum RovoDevIndex {
    public static func defaultSessionsRoot() -> String {
        ("~/.rovodev/sessions" as NSString).expandingTildeInPath
    }

    public static func loadSessions(
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int,
        sessionsRoot: String = Self.defaultSessionsRoot()
    ) -> RovoDevIndexResult {
        guard limit > 0 else { return RovoDevIndexResult(sessions: [], errors: []) }
        guard offset >= 0 else { return RovoDevIndexResult(sessions: [], errors: []) }
        let (target, overflow) = offset.addingReportingOverflow(limit)
        guard !overflow else { return RovoDevIndexResult(sessions: [], errors: []) }

        let normalizedNeedle = needle.lowercased()
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: sessionsRoot, isDirectory: true)
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return RovoDevIndexResult(sessions: [], errors: [])
        }

        var errors: [String] = []
        let sessionURLs: [URL]
        do {
            sessionURLs = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return RovoDevIndexResult(
                sessions: [],
                errors: ["Rovo Dev: cannot read sessions directory \(rootURL.path) (\(error.localizedDescription))"]
            )
        }

        var candidates: [RovoDevSessionCandidate] = []
        candidates.reserveCapacity(sessionURLs.count)
        for sessionURL in sessionURLs {
            let sessionValues: URLResourceValues
            do {
                sessionValues = try sessionURL.resourceValues(forKeys: [.isDirectoryKey])
            } catch {
                errors.append("Rovo Dev: cannot inspect session directory \(sessionURL.path) (\(error.localizedDescription))")
                continue
            }
            guard sessionValues.isDirectory == true else { continue }

            let metadataURL = sessionURL.appendingPathComponent("metadata.json", isDirectory: false)
            guard fileManager.fileExists(atPath: metadataURL.path) else { continue }

            let metadataValues: URLResourceValues
            do {
                metadataValues = try metadataURL.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                )
            } catch {
                errors.append("Rovo Dev: cannot inspect \(metadataURL.path) (\(error.localizedDescription))")
                continue
            }
            guard metadataValues.isRegularFile == true,
                  let mtime = metadataValues.contentModificationDate else {
                continue
            }

            let sessionContextURL = sessionURL.appendingPathComponent("session_context.json", isDirectory: false)
            candidates.append(RovoDevSessionCandidate(
                sessionId: sessionURL.lastPathComponent,
                metadataURL: metadataURL,
                sessionContextURL: sessionContextURL,
                mtime: max(mtime, Self.contentModificationDate(ofRegularFile: sessionContextURL) ?? mtime)
            ))
        }
        candidates.sort { $0.mtime > $1.mtime }

        var matchedCount = 0
        var sessions: [RovoDevIndexedSession] = []
        sessions.reserveCapacity(limit)

        for candidate in candidates {
            if Task.isCancelled { break }
            if matchedCount >= target { break }

            let metadata: [String: Any]
            do {
                let data = try Data(contentsOf: candidate.metadataURL)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw RovoDevMetadataError.notObject
                }
                metadata = object
            } catch {
                errors.append("Rovo Dev: cannot read metadata \(candidate.metadataURL.path) (\(error.localizedDescription))")
                continue
            }

            let title = RovoDevMetadataFields.title(from: metadata) ?? ""
            let cwd = RovoDevMetadataFields.workspacePath(from: metadata)
            if !workspacePath(cwd, matchesFilter: cwdFilter) {
                continue
            }
            if !normalizedNeedle.isEmpty {
                let haystack = [candidate.sessionId, title, cwd ?? ""]
                    .joined(separator: " ")
                    .lowercased()
                guard haystack.range(of: normalizedNeedle, options: [.literal]) != nil else {
                    continue
                }
            }

            if matchedCount >= offset {
                sessions.append(RovoDevIndexedSession(
                    sessionId: candidate.sessionId,
                    title: title,
                    workspacePath: cwd,
                    modified: candidate.mtime,
                    sessionContextURL: regularFileURL(candidate.sessionContextURL)
                ))
            }
            matchedCount += 1
        }
        return RovoDevIndexResult(sessions: sessions, errors: errors)
    }

    private static func regularFileURL(_ url: URL) -> URL? {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return nil
        }
        return url
    }

    public static func contentModificationDate(ofRegularFile url: URL) -> Date? {
        guard let values = try? url.resourceValues(
            forKeys: [.contentModificationDateKey, .isRegularFileKey]
        ),
              values.isRegularFile == true else {
            return nil
        }
        return values.contentModificationDate
    }

    private static func workspacePath(_ workspacePath: String?, matchesFilter filter: String?) -> Bool {
        guard let filter else { return true }
        guard let workspace = Self.normalizedPath(workspacePath),
              let target = Self.normalizedPath(filter) else {
            return false
        }
        return workspace == target
    }

    public static func normalizedPath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }
}

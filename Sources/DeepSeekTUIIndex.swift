import CMUXAgentLaunch
import Foundation

struct DeepSeekTUIIndexedSession: Equatable, Sendable {
    let sessionId: String
    let title: String
    let workspacePath: String?
    let modified: Date
    let sessionURL: URL
}

struct DeepSeekTUIIndexResult: Equatable, Sendable {
    let sessions: [DeepSeekTUIIndexedSession]
    let errors: [String]
}

private struct DeepSeekTUISessionEnvelope: Decodable {
    let metadata: DeepSeekTUISessionMetadata
}

private struct DeepSeekTUISessionMetadata: Decodable {
    let id: String
    let title: String?
    let updatedAt: Date
    let workspace: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case updatedAt = "updated_at"
        case workspace
    }
}

private struct DeepSeekTUISessionCandidate: Sendable {
    let url: URL
    let mtime: Date
}

enum DeepSeekTUIIndex {
    static func defaultSessionsRoot(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        DeepSeekTUISessionResolver.sessionsRoot(env: env)
    }

    static func loadSessions(
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int,
        sessionsRoot: String = Self.defaultSessionsRoot()
    ) -> DeepSeekTUIIndexResult {
        guard limit > 0 else { return DeepSeekTUIIndexResult(sessions: [], errors: []) }
        guard offset >= 0 else { return DeepSeekTUIIndexResult(sessions: [], errors: []) }
        let (target, overflow) = offset.addingReportingOverflow(limit)
        guard !overflow else { return DeepSeekTUIIndexResult(sessions: [], errors: []) }

        let rootURL = URL(fileURLWithPath: sessionsRoot, isDirectory: true)
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return DeepSeekTUIIndexResult(sessions: [], errors: [])
        }

        let sessionURLs: [URL]
        do {
            sessionURLs = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return DeepSeekTUIIndexResult(
                sessions: [],
                errors: ["DeepSeek-TUI: cannot read sessions directory \(rootURL.path) (\(error.localizedDescription))"]
            )
        }

        var errors: [String] = []
        let candidates = sessionURLs.compactMap { url -> DeepSeekTUISessionCandidate? in
            guard url.pathExtension == "json" else { return nil }
            do {
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values.isRegularFile == true else { return nil }
                return DeepSeekTUISessionCandidate(
                    url: url,
                    mtime: values.contentModificationDate ?? .distantPast
                )
            } catch {
                errors.append("DeepSeek-TUI: cannot inspect \(url.path) (\(error.localizedDescription))")
                return nil
            }
        }.sorted { $0.mtime > $1.mtime }

        var matchedCount = 0
        var sessions: [DeepSeekTUIIndexedSession] = []
        sessions.reserveCapacity(limit)
        let normalizedNeedle = needle.lowercased()

        for candidate in candidates {
            if Task.isCancelled { break }
            if matchedCount >= target { break }

            let envelope: DeepSeekTUISessionEnvelope
            do {
                let data = try Data(contentsOf: candidate.url)
                envelope = try Self.decoder.decode(DeepSeekTUISessionEnvelope.self, from: data)
            } catch {
                errors.append("DeepSeek-TUI: cannot read session \(candidate.url.path) (\(error.localizedDescription))")
                continue
            }

            let metadata = envelope.metadata
            let cwd = metadata.workspace
            if let cwdFilter, cwd != cwdFilter {
                continue
            }
            let title = metadata.title ?? ""
            if !normalizedNeedle.isEmpty {
                let haystack = [metadata.id, title, cwd ?? ""]
                    .joined(separator: " ")
                    .lowercased()
                guard haystack.range(of: normalizedNeedle, options: [.literal]) != nil else {
                    continue
                }
            }

            if matchedCount >= offset {
                sessions.append(DeepSeekTUIIndexedSession(
                    sessionId: metadata.id,
                    title: title,
                    workspacePath: cwd,
                    modified: metadata.updatedAt,
                    sessionURL: candidate.url
                ))
            }
            matchedCount += 1
        }

        return DeepSeekTUIIndexResult(sessions: sessions, errors: errors)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = fractionalISO8601.date(from: raw) ?? plainISO8601.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date: \(raw)"
            )
        }
        return decoder
    }()

    private static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

extension SessionIndexStore {
    nonisolated static func loadDeepSeekTUIEntries(
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int,
        errorBag: ErrorBag,
        sessionsRoot: String = DeepSeekTUIIndex.defaultSessionsRoot()
    ) -> [SessionEntry] {
        let result = DeepSeekTUIIndex.loadSessions(
            needle: needle,
            cwdFilter: cwdFilter,
            offset: offset,
            limit: limit,
            sessionsRoot: sessionsRoot
        )
        for error in result.errors {
            errorBag.add(error)
        }
        return result.sessions.map { session in
            SessionEntry(
                id: "deepseek-tui:" + session.sessionId,
                agent: .deepseekTUI,
                sessionId: session.sessionId,
                title: session.title,
                cwd: session.workspacePath,
                gitBranch: nil,
                pullRequest: nil,
                modified: session.modified,
                fileURL: session.sessionURL,
                specifics: .deepseekTUI
            )
        }
    }

    #if DEBUG
    nonisolated static func loadDeepSeekTUIEntriesForTesting(
        sessionsRoot: String,
        needle: String = "",
        cwdFilter: String? = nil,
        offset: Int = 0,
        limit: Int = 100
    ) -> SearchOutcome {
        let bag = ErrorBag()
        let entries = loadDeepSeekTUIEntries(
            needle: needle,
            cwdFilter: cwdFilter,
            offset: offset,
            limit: limit,
            errorBag: bag,
            sessionsRoot: sessionsRoot
        )
        return SearchOutcome(entries: entries, errors: bag.snapshot())
    }
    #endif
}

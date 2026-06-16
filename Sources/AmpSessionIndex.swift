import Foundation

// Amp (Sourcegraph Amp CLI) no longer keeps a stable local thread store: thread
// content now lives server-side and the legacy `~/.local/share/amp/threads/*.json`
// files are abandoned. The authoritative local record of Amp sessions is cmux's
// own per-agent hook store at `~/.cmuxterm/amp-hook-sessions.json`, written by the
// bundled Amp plugin via `cmux hooks amp`. We read that store (read-only) to list
// resumable Amp sessions, independent of Amp's server migration.

/// One Amp session record as written by `cmux hooks amp`. Decoding is tolerant:
/// every field beyond the dictionary key is optional so a CLI schema bump never
/// breaks the Session Index listing.
private struct AmpHookSessionRecord: Decodable {
    var sessionId: String?
    var cwd: String?
    var startedAt: TimeInterval?
    var updatedAt: TimeInterval?
    var title: String?
    var launchCommand: LaunchCommand?

    struct LaunchCommand: Decodable {
        var launcher: String?
        var executablePath: String?
        var arguments: [String]?
        var workingDirectory: String?
        var environment: [String: String]?
        var capturedAt: TimeInterval?
        var source: String?

        var snapshot: AgentLaunchCommandSnapshot? {
            guard launcher != nil || executablePath != nil || !(arguments?.isEmpty ?? true) || !(environment?.isEmpty ?? true) else {
                return nil
            }
            AgentLaunchCommandSnapshot(
                launcher: launcher,
                executablePath: executablePath,
                arguments: arguments ?? [],
                workingDirectory: workingDirectory,
                environment: environment,
                capturedAt: capturedAt,
                source: source
            )
        }
    }
}

private struct AmpHookSessionStoreFile: Decodable {
    var sessions: [String: AmpHookSessionRecord]

    private enum CodingKeys: String, CodingKey { case sessions }

    private struct SessionKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.sessions) else {
            sessions = [:]
            return
        }
        // Decode entry-by-entry so one type-drifted record (this is persisted
        // cross-version state) can't blank the whole listing.
        let sessionsContainer = try container.nestedContainer(
            keyedBy: SessionKey.self,
            forKey: .sessions
        )
        var decoded: [String: AmpHookSessionRecord] = [:]
        decoded.reserveCapacity(sessionsContainer.allKeys.count)
        for key in sessionsContainer.allKeys {
            guard let record = try? sessionsContainer.decode(
                AmpHookSessionRecord.self,
                forKey: key
            ) else { continue }
            decoded[key.stringValue] = record
        }
        sessions = decoded
    }
}

private struct AmpIndexedSession {
    let sessionId: String
    let title: String
    let cwd: String?
    let launchCommand: AgentLaunchCommandSnapshot?
    let modified: Date
}

extension SessionIndexStore {
    nonisolated static func loadAmpEntries(
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int,
        errorBag: ErrorBag,
        storeURL: URL = RestorableAgentKind.amp.hookStoreFileURL()
    ) -> [SessionEntry] {
        guard limit > 0, offset >= 0 else { return [] }
        let (target, overflow) = offset.addingReportingOverflow(limit)
        guard !overflow else { return [] }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: storeURL.path) else { return [] }

        let store: AmpHookSessionStoreFile
        do {
            let data = try Data(contentsOf: storeURL)
            store = try JSONDecoder().decode(AmpHookSessionStoreFile.self, from: data)
        } catch {
            errorBag.add(String(
                localized: "sessionIndex.error.ampStoreRead",
                defaultValue: "Amp: cannot read amp-hook-sessions.json"
            ))
            return []
        }

        var indexed: [AmpIndexedSession] = []
        indexed.reserveCapacity(store.sessions.count)
        for (key, record) in store.sessions {
            let sessionId = (record.sessionId ?? key).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sessionId.isEmpty else { continue }

            let cwd = Self.ampNormalizedCwd(record.cwd ?? record.launchCommand?.workingDirectory)
            // Prefer updatedAt, then startedAt; epoch seconds.
            let modified = Date(timeIntervalSince1970: record.updatedAt ?? record.startedAt ?? 0)
            indexed.append(AmpIndexedSession(
                sessionId: sessionId,
                title: Self.ampDisplayTitle(recordTitle: record.title, cwd: cwd),
                cwd: cwd,
                launchCommand: record.launchCommand?.snapshot,
                modified: modified
            ))
        }

        indexed.sort { lhs, rhs in
            lhs.modified == rhs.modified
                ? lhs.sessionId < rhs.sessionId
                : lhs.modified > rhs.modified
        }

        let normalizedNeedle = needle.lowercased()
        let normalizedFilter = cwdFilter.flatMap { Self.ampNormalizedCwd($0) }
        var matchedCount = 0
        var entries: [SessionEntry] = []
        entries.reserveCapacity(limit)

        for session in indexed {
            if matchedCount >= target { break }
            if let normalizedFilter, session.cwd != normalizedFilter { continue }
            if !normalizedNeedle.isEmpty {
                let haystack = [session.sessionId, session.title, session.cwd ?? ""]
                    .joined(separator: " ")
                    .lowercased()
                guard haystack.range(of: normalizedNeedle, options: [.literal]) != nil else { continue }
            }
            if matchedCount >= offset {
                entries.append(SessionEntry(
                    id: "amp:" + session.sessionId,
                    agent: .amp,
                    sessionId: session.sessionId,
                    title: session.title,
                    cwd: session.cwd,
                    gitBranch: nil,
                    pullRequest: nil,
                    modified: session.modified,
                    fileURL: nil,
                    specifics: .amp(launchCommand: session.launchCommand)
                ))
            }
            matchedCount += 1
        }
        return entries
    }

    /// Use the stored title when present; otherwise synthesize a readable label
    /// from the working directory, falling back to a generic one.
    private nonisolated static func ampDisplayTitle(recordTitle: String?, cwd: String?) -> String {
        if let recordTitle = recordTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !recordTitle.isEmpty {
            return recordTitle
        }
        if let cwd {
            let basename = (cwd as NSString).lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !basename.isEmpty {
                return String(format: String(
                    localized: "sessionIndex.amp.titleInDirectory",
                    defaultValue: "Amp session in %@"
                ), basename)
            }
        }
        return String(localized: "sessionIndex.amp.title", defaultValue: "Amp session")
    }

    // Match SessionIndexStore.normalizedDirectory: standardizingPath (no symlink
    // resolution) so Amp cwds bucket and scope-filter the same way as every other
    // agent's entries.
    private nonisolated static func ampNormalizedCwd(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        var normalized = (NSString(string: trimmed).expandingTildeInPath as NSString).standardizingPath
        if normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    #if DEBUG
    nonisolated static func loadAmpEntriesForTesting(
        storeURL: URL,
        needle: String = "",
        cwdFilter: String? = nil,
        offset: Int = 0,
        limit: Int = 100
    ) -> SearchOutcome {
        let bag = ErrorBag()
        let entries = loadAmpEntries(
            needle: needle,
            cwdFilter: cwdFilter,
            offset: offset,
            limit: limit,
            errorBag: bag,
            storeURL: storeURL
        )
        return SearchOutcome(entries: entries, errors: bag.snapshot())
    }
    #endif
}

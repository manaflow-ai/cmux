import CMUXAgentLaunch
import Foundation

extension SessionIndexStore {
    /// Loads sessions from a registry-owned cmux hook store.
    nonisolated static func loadCmuxHookStoreEntries(
        registration: CmuxVaultAgentRegistration,
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int,
        errorBag: ErrorBag,
        storeURL: URL? = nil
    ) -> [SessionEntry] {
        guard limit > 0, offset >= 0,
              let source = registration.cmuxHookSessionStore else {
            return []
        }
        let (target, overflow) = offset.addingReportingOverflow(limit)
        guard !overflow else { return [] }

        switch source {
        case .amp:
            return loadAmpHookStoreEntries(
                registration: registration,
                needle: needle,
                cwdFilter: cwdFilter,
                offset: offset,
                target: target,
                limit: limit,
                errorBag: errorBag,
                storeURL: storeURL ?? RestorableAgentKind.amp.hookStoreFileURL()
            )
        }
    }

    private nonisolated static func loadAmpHookStoreEntries(
        registration: CmuxVaultAgentRegistration,
        needle: String,
        cwdFilter: String?,
        offset: Int,
        target: Int,
        limit: Int,
        errorBag: ErrorBag,
        storeURL: URL
    ) -> [SessionEntry] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: storeURL.path) else { return [] }

        let store: AmpVaultHookSessionStoreFile
        do {
            store = try JSONDecoder().decode(
                AmpVaultHookSessionStoreFile.self,
                from: Data(contentsOf: storeURL)
            )
        } catch {
            errorBag.add(String(
                localized: "sessionIndex.error.ampStoreRead",
                defaultValue: "Amp: cannot read amp-hook-sessions.json"
            ))
            return []
        }

        var indexed: [(
            sessionId: String,
            title: String,
            cwd: String?,
            launchCommand: AgentLaunchCommandSnapshot?,
            modified: Date
        )] = []
        indexed.reserveCapacity(store.sessions.count)
        for (key, record) in store.sessions {
            let sessionId = (record.sessionId ?? key)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard AgentRestoreLaunch(kind: "amp", sessionID: sessionId) != nil else {
                continue
            }
            let launchCommand = trustedAmpLaunchCommand(record.launchCommand)
            let cwd = normalizedAmpWorkingDirectory(record.cwd ?? launchCommand?.workingDirectory)
            indexed.append((
                sessionId: sessionId,
                title: ampDisplayTitle(record.title, cwd: cwd),
                cwd: cwd,
                launchCommand: launchCommand,
                modified: Date(timeIntervalSince1970: record.updatedAt ?? record.startedAt ?? 0)
            ))
        }
        indexed.sort { lhs, rhs in
            lhs.modified == rhs.modified
                ? lhs.sessionId < rhs.sessionId
                : lhs.modified > rhs.modified
        }

        let normalizedNeedle = needle.lowercased()
        let normalizedFilter = normalizedAmpWorkingDirectory(cwdFilter)
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
                guard haystack.range(of: normalizedNeedle, options: [.literal]) != nil else {
                    continue
                }
            }
            if matchedCount >= offset {
                entries.append(SessionEntry(
                    id: "\(registration.id):\(session.sessionId)",
                    agent: .registered(RegisteredSessionAgent(registration: registration)),
                    sessionId: session.sessionId,
                    title: session.title,
                    cwd: session.cwd,
                    gitBranch: nil,
                    pullRequest: nil,
                    modified: session.modified,
                    fileURL: nil,
                    specifics: .registered(
                        registration,
                        launchCommand: session.launchCommand
                    )
                ))
            }
            matchedCount += 1
        }
        return entries
    }

    private nonisolated static func trustedAmpLaunchCommand(
        _ launchCommand: AgentLaunchCommandSnapshot?
    ) -> AgentLaunchCommandSnapshot? {
        guard let launchCommand,
              !launchCommand.arguments.isEmpty,
              AgentLaunchCaptureTrust.launcherDescribesKind(
                  launchCommand.launcher,
                  kind: RestorableAgentKind.amp.rawValue
              ),
              AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                  processName: launchCommand.executablePath,
                  arguments: launchCommand.arguments,
                  kind: RestorableAgentKind.amp.rawValue
              ),
              !AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(launchCommand.arguments) else {
            return nil
        }
        return launchCommand
    }

    private nonisolated static func normalizedAmpWorkingDirectory(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        var normalized = ((value as NSString).expandingTildeInPath as NSString).standardizingPath
        if normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private nonisolated static func ampDisplayTitle(_ title: String?, cwd: String?) -> String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        if let cwd {
            let directory = (cwd as NSString).lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !directory.isEmpty {
                return String.localizedStringWithFormat(
                    String(
                        localized: "sessionIndex.amp.titleInDirectory",
                        defaultValue: "Amp session in %@"
                    ),
                    directory
                )
            }
        }
        return String(localized: "sessionIndex.amp.title", defaultValue: "Amp session")
    }
}

private extension CmuxVaultAgentRegistration {
    var cmuxHookSessionStore: CmuxVaultHookSessionStore? {
        guard case .cmuxHookStore(let store) = sessionIdSource else { return nil }
        return store
    }
}

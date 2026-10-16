import CmuxAgentSessionStore
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
        repository: any AmpHookSessionReading,
        storeURL: URL? = nil
    ) async -> [SessionEntry] {
        guard case .cmuxHookStore(let source) = registration.sessionIdSource else {
            return []
        }

        switch source {
        case .amp:
            do {
                let snapshots = try await repository.snapshots(
                    at: storeURL ?? RestorableAgentKind.amp.hookStoreFileURL(),
                    matching: needle,
                    workingDirectory: cwdFilter,
                    offset: offset,
                    limit: limit
                )
                return snapshots.map { snapshot in
                    SessionEntry(
                        id: "\(registration.id):\(snapshot.sessionID)",
                        agent: .registered(RegisteredSessionAgent(registration: registration)),
                        sessionId: snapshot.sessionID,
                        title: ampDisplayTitle(
                            snapshot.title,
                            workingDirectory: snapshot.workingDirectory
                        ),
                        cwd: snapshot.workingDirectory,
                        gitBranch: nil,
                        pullRequest: nil,
                        modified: snapshot.modified,
                        fileURL: nil,
                        specifics: .registered(
                            registration,
                            launchCommand: snapshot.launchCommand
                        )
                    )
                }
            } catch {
                errorBag.add(String(
                    localized: "sessionIndex.error.ampStoreRead",
                    defaultValue: "Session history is unavailable"
                ))
                return []
            }
        }
    }

    private nonisolated static func ampDisplayTitle(
        _ title: String?,
        workingDirectory: String?
    ) -> String {
        if let title {
            return title
        }
        if let workingDirectory {
            let directory = (workingDirectory as NSString).lastPathComponent
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

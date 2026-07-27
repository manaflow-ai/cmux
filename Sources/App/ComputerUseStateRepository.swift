import Foundation

/// Reads and validates the computer-use driver's untrusted per-process state files.
struct ComputerUseStateRepository: Sendable {
    static let defaultRecentActivityInterval: TimeInterval = 60 * 60
    private static let maximumStateFileBytes = 64 * 1_024
    private static let maximumDirectoryEntries = 512
    private static let maximumCandidateFiles = 128
    private static let maximumFutureClockSkew: TimeInterval = 5 * 60
    private static let stateSuffix = ".json"
    private static let cursorSuffix = ".cursor.json"

    let recentActivityInterval: TimeInterval
    let authenticationKey: Data

    init(
        recentActivityInterval: TimeInterval = Self.defaultRecentActivityInterval,
        authenticationKey: Data
    ) {
        self.recentActivityInterval = recentActivityInterval
        self.authenticationKey = authenticationKey
    }

    func scan(
        directoryURL: URL,
        sessions: [ComputerUseSessionScope],
        now: Date,
        fileManager: FileManager = .default,
        isStateEligible: @Sendable (
            ComputerUseSessionScope,
            ComputerUseDriverState
        ) -> Bool = { _, _ in true }
    ) -> ComputerUseStateScan {
        guard
            let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                ],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        else {
            return .empty
        }

        var inspectedEntries = 0
        var candidates: [(url: URL, size: Int, modifiedAt: Date)] = []
        for case let url as URL in enumerator {
            inspectedEntries += 1
            // The private runtime normally contains only a few state/cursor
            // files. Fail closed instead of turning a filesystem event into an
            // unbounded scan if stale or attacker-created entries accumulate.
            guard inspectedEntries <= Self.maximumDirectoryEntries else {
                return .empty
            }
            let name = url.lastPathComponent
            guard
                name.hasSuffix(Self.stateSuffix),
                !name.hasSuffix(Self.cursorSuffix),
                let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                ]),
                values.isRegularFile == true,
                values.isSymbolicLink != true,
                let fileSize = values.fileSize,
                fileSize > 0,
                fileSize <= Self.maximumStateFileBytes
            else {
                continue
            }
            candidates.append((
                url: url,
                size: fileSize,
                modifiedAt: values.contentModificationDate ?? .distantPast
            ))
        }
        candidates.sort { $0.modifiedAt > $1.modifiedAt }

        var scopeIDsByDriverSessionID: [String: [String]] = [:]
        var sessionsByScopeID: [String: ComputerUseSessionScope] = [:]
        for session in sessions {
            scopeIDsByDriverSessionID[session.driverSessionID, default: []].append(session.id)
            sessionsByScopeID[session.id] = session
        }

        var newestStateByScopeID: [String: ComputerUseDriverState] = [:]
        var hasRecentStateFiles = false
        for candidate in candidates.prefix(Self.maximumCandidateFiles) {
            guard !Task.isCancelled else { return .empty }
            guard
                let data = try? Data(
                    contentsOf: candidate.url,
                    options: [.mappedIfSafe]
                ),
                data.count == candidate.size,
                let state = ComputerUseDriverState(
                    data: data,
                    authenticationKey: authenticationKey
                ),
                isRecent(state.lastActionAt, now: now)
            else {
                continue
            }
            hasRecentStateFiles = true
            guard let candidate = state.session else { continue }
            let exactScopeIDs = scopeIDsByDriverSessionID[candidate]
            let baseCandidate = candidate.range(of: "-mcp-").map {
                String(candidate[..<$0.lowerBound])
            }
            let matchingScopeIDs = exactScopeIDs
                ?? baseCandidate.flatMap { scopeIDsByDriverSessionID[$0] }
                ?? []
            for scopeID in matchingScopeIDs {
                guard
                    (newestStateByScopeID[scopeID]?.lastActionAt ?? .distantPast)
                        < state.lastActionAt,
                    sessionsByScopeID[scopeID].map({
                        isStateEligible($0, state)
                    }) == true
                else {
                    continue
                }
                newestStateByScopeID[scopeID] = state
            }
        }

        return ComputerUseStateScan(
            newestStateByScopeID: newestStateByScopeID,
            hasRecentStateFiles: hasRecentStateFiles
        )
    }

    static func defaultStateDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("computer-use", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
    }

    private func isRecent(_ date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= -Self.maximumFutureClockSkew && age <= recentActivityInterval
    }
}

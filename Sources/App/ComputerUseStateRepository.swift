import Foundation

/// Reads and validates the computer-use driver's untrusted per-process state files.
struct ComputerUseStateRepository: Sendable {
    static let defaultRecentActivityInterval: TimeInterval = 60 * 60
    private static let maximumStateFileBytes = 64 * 1_024
    private static let maximumFutureClockSkew: TimeInterval = 5 * 60

    let recentActivityInterval: TimeInterval

    init(recentActivityInterval: TimeInterval = Self.defaultRecentActivityInterval) {
        self.recentActivityInterval = recentActivityInterval
    }

    func scan(
        directoryURL: URL,
        sessions: [ComputerUseSessionScope],
        now: Date,
        fileManager: FileManager = .default
    ) -> ComputerUseStateScan {
        guard
            let urls = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return .empty
        }

        var scopeIDsByDriverSessionID: [String: [String]] = [:]
        for session in sessions {
            scopeIDsByDriverSessionID[session.driverSessionID, default: []].append(session.id)
        }

        var newestStateByScopeID: [String: ComputerUseDriverState] = [:]
        var hasRecentStateFiles = false
        for url in urls {
            guard !Task.isCancelled else { return .empty }
            guard
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                values.isRegularFile == true,
                values.isSymbolicLink != true,
                let fileSize = values.fileSize,
                fileSize > 0,
                fileSize <= Self.maximumStateFileBytes,
                let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                let state = ComputerUseDriverState(data: data),
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
            for scopeID in matchingScopeIDs
                where (newestStateByScopeID[scopeID]?.lastActionAt ?? .distantPast) < state.lastActionAt {
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

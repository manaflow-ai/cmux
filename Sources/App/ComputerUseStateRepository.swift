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

        var recentStates: [ComputerUseDriverState] = []
        recentStates.reserveCapacity(urls.count)
        for url in urls {
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
            recentStates.append(state)
        }

        var newestStateByScopeID: [String: ComputerUseDriverState] = [:]
        for session in sessions {
            // Every cmux wrapper gives the driver a stable per-surface session
            // identity. Pair on that direct identity so state refreshes never
            // need a machine-wide process-tree capture.
            newestStateByScopeID[session.id] = recentStates
                .filter { state in session.matches(driverSessionID: state.session) }
                .max { $0.lastActionAt < $1.lastActionAt }
        }

        return ComputerUseStateScan(
            newestStateByScopeID: newestStateByScopeID,
            hasRecentStateFiles: !recentStates.isEmpty
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

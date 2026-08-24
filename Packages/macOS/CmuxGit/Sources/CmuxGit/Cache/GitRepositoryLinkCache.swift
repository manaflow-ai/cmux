import Foundation

/// Caches a repository remote link while its reachable config files are unchanged.
actor GitRepositoryLinkCache {
    private struct Key: Hashable {
        let workTreeRoot: String
        let gitDirectory: String
        let commonDirectory: String

        init(repository: ResolvedGitRepository) {
            workTreeRoot = repository.workTreeRoot
            gitDirectory = repository.gitDirectory
            commonDirectory = repository.commonDirectory
        }
    }

    private struct Entry {
        let configStatuses: [String: GitFileStatus?]
        let headSignature: String?
        let link: GitRepositoryLink?
    }

    private let maximumEntryCount: Int
    private var entries: [Key: Entry] = [:]
    private var keysInUseOrder: [Key] = []

    init(maximumEntryCount: Int = 128) {
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    func cachedLink(
        repository: ResolvedGitRepository,
        headSignature: String?,
        fileStatusReader: any GitFileStatusReading
    ) -> GitRepositoryLink?? {
        let key = Key(repository: repository)
        guard let entry = entries[key] else { return nil }
        guard entry.headSignature == headSignature else {
            entries.removeValue(forKey: key)
            keysInUseOrder.removeAll { $0 == key }
            return nil
        }
        for (path, previousStatus) in entry.configStatuses {
            guard fileStatusReader.status(atPath: path) == previousStatus else {
                entries.removeValue(forKey: key)
                keysInUseOrder.removeAll { $0 == key }
                return nil
            }
        }
        markRecentlyUsed(key)
        return .some(entry.link)
    }

    func store(
        link: GitRepositoryLink?,
        repository: ResolvedGitRepository,
        configURLs: [URL],
        headSignature: String?,
        fileStatusReader: any GitFileStatusReading
    ) {
        let key = Key(repository: repository)
        var statuses: [String: GitFileStatus?] = [:]
        for configURL in configURLs {
            let path = configURL.standardizedFileURL.path
            statuses.updateValue(fileStatusReader.status(atPath: path), forKey: path)
        }
        entries[key] = Entry(configStatuses: statuses, headSignature: headSignature, link: link)
        markRecentlyUsed(key)
        trimIfNeeded()
    }

    private func markRecentlyUsed(_ key: Key) {
        keysInUseOrder.removeAll { $0 == key }
        keysInUseOrder.append(key)
    }

    private func trimIfNeeded() {
        while entries.count > maximumEntryCount, let oldest = keysInUseOrder.first {
            keysInUseOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }
}

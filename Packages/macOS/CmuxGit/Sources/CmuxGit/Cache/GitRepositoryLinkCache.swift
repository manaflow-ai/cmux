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
    private let maximumDependencyPathCount: Int
    private let maximumDependencyPathBytes: Int
    private var entries: [Key: Entry] = [:]
    private var keysInUseOrder: [Key] = []

    init(
        maximumEntryCount: Int = 128,
        maximumDependencyPathCount: Int = 512,
        maximumDependencyPathBytes: Int = 64 * 1024
    ) {
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.maximumDependencyPathCount = max(1, maximumDependencyPathCount)
        self.maximumDependencyPathBytes = max(1, maximumDependencyPathBytes)
    }

    func cachedLink(
        repository: ResolvedGitRepository,
        headSignature: String?,
        fileStatusReader: any GitFileStatusReading
    ) -> GitRepositoryLink?? {
        let key = Key(repository: repository)
        guard let entry = entries[key] else { return nil }
        guard entry.headSignature == headSignature else {
            removeEntry(for: key)
            return nil
        }
        for (path, previousStatus) in entry.configStatuses {
            guard fileStatusReader.status(atPath: path) == previousStatus else {
                removeEntry(for: key)
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
        expectedConfigStatuses: [String: GitFileStatus?] = [:],
        headSignature: String?,
        fileStatusReader: any GitFileStatusReading
    ) {
        let key = Key(repository: repository)
        var paths: Set<String> = []
        var pathBytes = 0
        for configURL in configURLs {
            let normalizedURL = configURL.standardizedFileURL
            let dependencyPaths = Set([
                normalizedURL.path,
                normalizedURL.resolvingSymlinksInPath().path
            ])
            for path in dependencyPaths where paths.insert(path).inserted {
                pathBytes += path.utf8.count
                guard paths.count <= maximumDependencyPathCount,
                      pathBytes <= maximumDependencyPathBytes else {
                    removeEntry(for: key)
                    return
                }
            }
        }
        var statuses: [String: GitFileStatus?] = [:]
        for path in paths {
            statuses.updateValue(fileStatusReader.status(atPath: path), forKey: path)
        }
        for (path, expectedStatus) in expectedConfigStatuses {
            guard statuses[path] == expectedStatus,
                  fileStatusReader.status(atPath: path) == expectedStatus else {
                removeEntry(for: key)
                return
            }
        }
        entries[key] = Entry(configStatuses: statuses, headSignature: headSignature, link: link)
        markRecentlyUsed(key)
        trimIfNeeded()
    }

    private func markRecentlyUsed(_ key: Key) {
        keysInUseOrder.removeAll { $0 == key }
        keysInUseOrder.append(key)
    }

    private func removeEntry(for key: Key) {
        entries.removeValue(forKey: key)
        keysInUseOrder.removeAll { $0 == key }
    }

    private func trimIfNeeded() {
        while entries.count > maximumEntryCount, let oldest = keysInUseOrder.first {
            keysInUseOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }
}

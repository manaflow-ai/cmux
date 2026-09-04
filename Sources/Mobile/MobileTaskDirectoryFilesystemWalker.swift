import Foundation

/// Scans the real directory tree breadth-first under strict visit, match, and
/// wall-clock budgets so directory search can find folders Spotlight has not
/// indexed. Every search pays only its own bounded scan; nothing is indexed
/// or persisted between searches.
struct MobileTaskDirectoryFilesystemWalker: Sendable {
    struct Budget: Sendable {
        /// Directories read before the scan stops.
        var maximumVisitedDirectories = 150_000
        /// Name matches collected before the scan stops.
        var maximumMatches = 256
        /// Wall-clock cap for one scan.
        var timeLimit: Duration = .milliseconds(1_500)
    }

    struct Outcome: Equatable, Sendable {
        var matches: [String]
        var visitedDirectoryCount: Int
        /// Whether every readable directory under the roots was scanned
        /// before a budget expired.
        var complete: Bool
    }

    /// Directory names the walk never descends into: dependency caches, build
    /// products, and the macOS Library tree. Hidden directories are also not
    /// descended into. A directory whose own name matches the query is still
    /// reported from its parent's listing.
    static let prunedDirectoryNames: Set<String> = [
        "node_modules", "bower_components", "Library", "DerivedData",
        "Pods", "Carthage", "venv", "__pycache__", "target",
        "zig-cache", "zig-out", "CMakeFiles",
    ]

    var budget = Budget()

    /// Walks `roots` breadth-first and returns every directory whose name
    /// contains the final path component of `query`, case-, diacritic-, and
    /// width-insensitively. Ranking against the full query happens upstream.
    func search(query: String, roots: [String]) -> Outcome {
        let foldedQuery = Self.fold(query)
        guard let queryBasename = Self.components(foldedQuery).last else {
            return Outcome(matches: [], visitedDirectoryCount: 0, complete: true)
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget.timeLimit)
        var queue: [String] = []
        var enqueued = Set<String>()
        for root in roots {
            let standardized = URL(fileURLWithPath: root, isDirectory: true)
                .standardizedFileURL.path
            if enqueued.insert(standardized).inserted {
                queue.append(standardized)
            }
        }

        var matches: [String] = []
        var visited = 0
        var head = 0
        var entriesSinceClockCheck = 0
        // Descents skipped once the enqueue budget is exhausted; the scan is
        // then incomplete even if the bounded queue drains fully.
        var enqueueOverflowed = false

        while head < queue.count {
            guard visited < budget.maximumVisitedDirectories, !Task.isCancelled else {
                return Outcome(matches: matches, visitedDirectoryCount: visited, complete: false)
            }
            let directory = queue[head]
            head += 1
            visited += 1

            // An unreadable directory is skipped, not treated as incomplete:
            // completeness describes budget exhaustion, and permission limits
            // surface through the picker's browse failures instead.
            guard let stream = opendir(directory) else { continue }
            defer { closedir(stream) }

            while let entry = readdir(stream) {
                entriesSinceClockCheck += 1
                if entriesSinceClockCheck >= 512 {
                    entriesSinceClockCheck = 0
                    if clock.now > deadline || Task.isCancelled {
                        return Outcome(
                            matches: matches,
                            visitedDirectoryCount: visited,
                            complete: false
                        )
                    }
                }

                let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                    String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                }
                guard name != ".", name != ".." else { continue }
                let path = directory == "/" ? "/" + name : directory + "/" + name

                guard Self.isDirectory(entryType: entry.pointee.d_type, path: path) else {
                    continue
                }
                if Self.fold(name).contains(queryBasename) {
                    matches.append(path)
                    if matches.count >= budget.maximumMatches {
                        return Outcome(
                            matches: matches,
                            visitedDirectoryCount: visited,
                            complete: false
                        )
                    }
                }
                if Self.shouldDescend(into: name) {
                    // Never queue more directories than the visit budget can
                    // process, so queue memory stays bounded by the budget.
                    if enqueued.count >= budget.maximumVisitedDirectories {
                        enqueueOverflowed = true
                    } else if enqueued.insert(path).inserted {
                        queue.append(path)
                    }
                }
            }
        }
        return Outcome(
            matches: matches,
            visitedDirectoryCount: visited,
            complete: !enqueueOverflowed
        )
    }

    static func shouldDescend(into name: String) -> Bool {
        !name.hasPrefix(".") && !prunedDirectoryNames.contains(name)
    }

    private static func isDirectory(entryType: UInt8, path: String) -> Bool {
        switch Int32(entryType) {
        case DT_DIR:
            return true
        case DT_UNKNOWN:
            // Network and some FUSE filesystems do not report a type from
            // readdir; one lstat resolves it without following symlinks.
            var status = stat()
            return lstat(path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFDIR
        default:
            return false
        }
    }

    static func fold(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    static func components(_ value: String) -> [String] {
        value.split { $0 == "/" || $0.isWhitespace }.map(String.init)
    }
}

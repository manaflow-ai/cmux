import CmuxFoundation
import Foundation

actor TextBoxMentionIndexStore {
    static let shared = TextBoxMentionIndexStore()

    private static let fileIndexTTL: TimeInterval = 30
    private static let maxCachedFileIndexes = 8
    private static let directorySeedBatchSize = 128
    private static let maxIndexedDirectories = 2000
    private static let maxIndexedFiles = 6000
    private static let rootSuggestionLimit = 200
    private static let suggestionLimit = 500
    private static let directorySkipPolicy = IndexedDirectorySkipPolicy()

    private let skillScanner = TextBoxMentionSkillScanner()

    private var fileIndexesByRoot: [String: TextBoxMentionCachedIndex] = [:]
    private var fileIndexRefreshTasks: [String: TextBoxMentionFileIndexRefreshTask] = [:]
    private var nextFileIndexRefreshTaskID: UInt64 = 0
    private var skillIndexesByRootKey: [String: TextBoxMentionCandidateIndex] = [:]

    func suggestions(
        for query: TextBoxMentionQuery,
        rootDirectory: String?
    ) async -> [TextBoxMentionSuggestion] {
        switch query.kind {
        case .file:
            guard let rootDirectory = Self.normalizedDirectory(rootDirectory) else { return [] }
            return await fileSuggestions(for: query, rootDirectory: rootDirectory)
        case .skill:
            let index = skillIndex(rootDirectory: Self.normalizedDirectory(rootDirectory))
            return index.rankedCandidates(
                matching: query.query,
                limit: Self.suggestionLimit,
                shouldCancel: { Task.isCancelled }
            )
                .map { $0.suggestion(trigger: query.trigger) }
        }
    }

    func warmIndexes(rootDirectory: String?) async {
        let normalizedRootDirectory = Self.normalizedDirectory(rootDirectory)
        _ = skillIndex(rootDirectory: normalizedRootDirectory)
        if let normalizedRootDirectory {
            _ = await fileIndex(rootDirectory: normalizedRootDirectory, now: Date())
        }
    }

    private func fileSuggestions(
        for query: TextBoxMentionQuery,
        rootDirectory: String
    ) async -> [TextBoxMentionSuggestion] {
        let now = Date()
        let trimmedQuery = query.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            if let cachedIndex = cachedFileIndex(rootDirectory: rootDirectory, now: now) {
                return cachedIndex.rankedCandidates(
                    matching: query.query,
                    limit: Self.suggestionLimit,
                    shouldCancel: { Task.isCancelled }
                )
                .map { $0.suggestion(trigger: query.trigger) }
            }

            refreshFileIndexInBackground(rootDirectory: rootDirectory, now: now)
            return await Self.scanRootFileSystemCandidates(rootURL: URL(
                fileURLWithPath: rootDirectory,
                isDirectory: true
            ))
            .prefix(Self.suggestionLimit)
            .map { $0.suggestion(trigger: query.trigger) }
        }

        let index = await fileIndex(rootDirectory: rootDirectory, now: now)
        if Task.isCancelled { return [] }

        var matches = index.rankedCandidates(
            matching: query.query,
            limit: Self.suggestionLimit,
            shouldCancel: { Task.isCancelled }
        )
        if Task.isCancelled { return [] }
        if matches.isEmpty {
            let refreshed = await refreshFileIndex(
                rootDirectory: rootDirectory,
                now: Date(),
                minimumStartedAt: now
            )
            if Task.isCancelled { return [] }
            matches = refreshed.rankedCandidates(
                matching: query.query,
                limit: Self.suggestionLimit,
                shouldCancel: { Task.isCancelled }
            )
            if Task.isCancelled { return [] }
        }
        return matches
            .map { $0.suggestion(trigger: query.trigger) }
    }

    private func cachedFileIndex(
        rootDirectory: String,
        now: Date
    ) -> TextBoxMentionCandidateIndex? {
        guard let cached = fileIndexesByRoot[rootDirectory] else {
            pruneFileIndexCache(now: now)
            return nil
        }
        guard now.timeIntervalSince(cached.createdAt) < Self.fileIndexTTL else {
            fileIndexesByRoot[rootDirectory] = nil
            pruneFileIndexCache(now: now)
            return nil
        }
        fileIndexesByRoot[rootDirectory] = TextBoxMentionCachedIndex(
            index: cached.index,
            createdAt: cached.createdAt,
            lastAccessedAt: now,
            refreshStartedAt: cached.refreshStartedAt
        )
        pruneFileIndexCache(now: now)
        return cached.index
    }

    private func fileIndex(
        rootDirectory: String,
        now: Date
    ) async -> TextBoxMentionCandidateIndex {
        if let cachedIndex = cachedFileIndex(rootDirectory: rootDirectory, now: now) {
            return cachedIndex
        }
        return await refreshFileIndex(rootDirectory: rootDirectory, now: now)
    }

    private func refreshFileIndex(
        rootDirectory: String,
        now: Date,
        minimumStartedAt: Date? = nil
    ) async -> TextBoxMentionCandidateIndex {
        // Coalesce concurrent refreshes: while one scan is in flight for a root,
        // additional keystrokes await the same scan instead of each spawning a
        // fresh (and expensive) `rg`/filesystem walk. The detached scan is not
        // cancelled, so a join here is correct even if the caller's lookup task is.
        let refreshTask = fileIndexRefreshTask(
            rootDirectory: rootDirectory,
            minimumStartedAt: minimumStartedAt
        )
        let index = await refreshTask.task.value
        storeFileIndex(
            rootDirectory: rootDirectory,
            index: index,
            refreshStartedAt: refreshTask.startedAt,
            refreshTaskID: refreshTask.id
        )
        return index
    }

    private func refreshFileIndexInBackground(rootDirectory: String, now: Date) {
        guard cachedFileIndex(rootDirectory: rootDirectory, now: now) == nil else { return }
        let refreshTask = fileIndexRefreshTask(rootDirectory: rootDirectory)
        Task { [rootDirectory, refreshTask] in
            let index = await refreshTask.task.value
            self.storeFileIndex(
                rootDirectory: rootDirectory,
                index: index,
                refreshStartedAt: refreshTask.startedAt,
                refreshTaskID: refreshTask.id
            )
        }
    }

    private func fileIndexRefreshTask(
        rootDirectory: String,
        minimumStartedAt: Date? = nil
    ) -> TextBoxMentionFileIndexRefreshTask {
        if let inFlight = fileIndexRefreshTasks[rootDirectory],
           minimumStartedAt.map({ inFlight.startedAt >= $0 }) ?? true {
            return inFlight
        }

        let rootURL = URL(fileURLWithPath: rootDirectory, isDirectory: true)
        let scanTask = Task<TextBoxMentionCandidateIndex, Never>.detached(priority: .utility) {
            let candidates = await Self.scanFiles(rootURL: rootURL)
            return TextBoxMentionCandidateIndex(candidates: candidates)
        }
        nextFileIndexRefreshTaskID &+= 1
        let refreshTask = TextBoxMentionFileIndexRefreshTask(
            id: nextFileIndexRefreshTaskID,
            startedAt: Date(),
            task: scanTask
        )
        fileIndexRefreshTasks[rootDirectory] = refreshTask
        return refreshTask
    }

    private func storeFileIndex(
        rootDirectory: String,
        index: TextBoxMentionCandidateIndex,
        refreshStartedAt: Date,
        refreshTaskID: UInt64
    ) {
        if let cached = fileIndexesByRoot[rootDirectory],
           cached.refreshStartedAt > refreshStartedAt {
            return
        }
        if fileIndexRefreshTasks[rootDirectory]?.id == refreshTaskID {
            fileIndexRefreshTasks[rootDirectory] = nil
        }
        let storedAt = Date()
        fileIndexesByRoot[rootDirectory] = TextBoxMentionCachedIndex(
            index: index,
            createdAt: storedAt,
            lastAccessedAt: storedAt,
            refreshStartedAt: refreshStartedAt
        )
        pruneFileIndexCache(now: storedAt)
    }

    private func pruneFileIndexCache(now: Date) {
        let expiredRoots = fileIndexesByRoot.compactMap { rootDirectory, cached in
            now.timeIntervalSince(cached.createdAt) >= Self.fileIndexTTL ? rootDirectory : nil
        }
        for rootDirectory in expiredRoots {
            fileIndexesByRoot[rootDirectory] = nil
        }

        guard fileIndexesByRoot.count > Self.maxCachedFileIndexes else { return }
        let rootsToRemove = fileIndexesByRoot
            .sorted { lhs, rhs in
                if lhs.value.lastAccessedAt != rhs.value.lastAccessedAt {
                    return lhs.value.lastAccessedAt < rhs.value.lastAccessedAt
                }
                return lhs.key < rhs.key
            }
            .prefix(fileIndexesByRoot.count - Self.maxCachedFileIndexes)
            .map(\.key)
        for rootDirectory in rootsToRemove {
            fileIndexesByRoot[rootDirectory] = nil
        }
    }

    private func skillIndex(rootDirectory: String?) -> TextBoxMentionCandidateIndex {
        let roots = skillScanner.searchRoots(rootDirectory: rootDirectory)
        let cacheKey = roots.map(\.path).joined(separator: "\n")
        if let cached = skillIndexesByRootKey[cacheKey] {
            return cached
        }

        let index = TextBoxMentionCandidateIndex(candidates: skillScanner.candidates(inRoots: roots))
        skillIndexesByRootKey[cacheKey] = index
        return index
    }

    private static func scanFiles(rootURL: URL) async -> [TextBoxMentionCandidate] {
        if let ripgrepCandidates = await scanFilesWithRipgrep(rootURL: rootURL) {
            return ripgrepCandidates
        }

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        let rootPath = rootURL.standardizedFileURL.path
        var directoryCandidates: [TextBoxMentionCandidate] = []
        var fileCandidates: [TextBoxMentionCandidate] = []
        var seenDirectoryRelativePaths = Set<String>()
        directoryCandidates.reserveCapacity(min(maxIndexedDirectories, 256))
        fileCandidates.reserveCapacity(min(maxIndexedFiles, 1024))

        func appendDirectoryCandidate(relativePath: String, directoryURL: URL) {
            guard !relativePath.isEmpty,
                  directoryCandidates.count < maxIndexedDirectories,
                  seenDirectoryRelativePaths.insert(relativePath).inserted else {
                return
            }
            directoryCandidates.append(TextBoxMentionCandidate.directoryCandidate(
                relativePath: relativePath,
                directoryURL: directoryURL
            ))
        }

        while let item = enumerator.nextObject() as? URL {
            let standardizedURL = item.standardizedFileURL
            let name = standardizedURL.lastPathComponent
            let values = try? standardizedURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if directorySkipPolicy.shouldSkip(name) {
                    enumerator.skipDescendants()
                    continue
                }
                appendDirectoryCandidate(
                    relativePath: standardizedURL.path.pathRelative(toRoot: rootPath),
                    directoryURL: standardizedURL
                )
                continue
            }
            guard values?.isRegularFile == true else { continue }

            let relativePath = standardizedURL.path.pathRelative(toRoot: rootPath)
            if fileCandidates.count < maxIndexedFiles {
                fileCandidates.append(TextBoxMentionCandidate.fileCandidate(
                    relativePath: relativePath,
                    fileURL: standardizedURL,
                    fileName: name
                ))
            }

            if fileCandidates.count >= maxIndexedFiles {
                break
            }
        }
        return TextBoxMentionCandidate.sortedFileSystemCandidates(directoryCandidates + fileCandidates)
    }

    private static func scanRootFileSystemCandidates(rootURL: URL) async -> [TextBoxMentionCandidate] {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let rootPath = rootURL.standardizedFileURL.path
        let candidateURLs = children
            .map(\.standardizedFileURL)
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values?.isDirectory == true {
                    return !directorySkipPolicy.shouldSkip(url.lastPathComponent)
                }
                return values?.isRegularFile == true
            }
        let relativePaths = candidateURLs.map {
            $0.path.pathRelative(toRoot: rootPath)
        }
        let ignoredRelativePaths = await isGitWorkTree(rootURL: rootURL)
            ? await gitIgnoredRelativePaths(rootURL: rootURL, relativePaths: relativePaths)
            : []

        var candidates: [TextBoxMentionCandidate] = []
        candidates.reserveCapacity(candidateURLs.count)
        for url in candidateURLs {
            let relativePath = url.path.pathRelative(toRoot: rootPath)
            guard !relativePath.isEmpty,
                  !ignoredRelativePaths.contains(relativePath),
                  !ignoredRelativePaths.contains("\(relativePath)/") else {
                continue
            }

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                candidates.append(TextBoxMentionCandidate.directoryCandidate(
                    relativePath: relativePath,
                    directoryURL: url
                ))
            } else if values?.isRegularFile == true {
                candidates.append(TextBoxMentionCandidate.fileCandidate(
                    relativePath: relativePath,
                    fileURL: url,
                    fileName: url.lastPathComponent
                ))
            }
        }
        return Array(TextBoxMentionCandidate.sortedFileSystemCandidates(candidates).prefix(rootSuggestionLimit))
    }

    private static func scanFilesWithRipgrep(rootURL: URL) async -> [TextBoxMentionCandidate]? {
        guard let executable = RipgrepExecutableResolver().resolve() else { return nil }

        let process = Process()
        process.executableURL = executable.url
        var arguments = executable.prefixArguments + [
            "--files",
            "--color", "never",
            "--no-messages"
        ]
        // Apply the same skip list as the fallback enumerator. rg honors
        // .gitignore in a git repo, but in a non-git root it would otherwise
        // descend into node_modules/vendor/Pods/etc. and blow the file budget.
        for name in directorySkipPolicy.skippedDirectoryNames.sorted() {
            arguments.append("--glob")
            arguments.append("!\(name)")
        }
        for suffix in directorySkipPolicy.skippedPackageDirectorySuffixes {
            arguments.append("--iglob")
            arguments.append("!*\(suffix)")
        }
        process.arguments = arguments
        process.currentDirectoryURL = rootURL

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let terminationStatus = TextBoxProcessTerminationStatus()
        process.terminationHandler = { process in
            let status = process.terminationStatus
            Task {
                await terminationStatus.finish(status: status)
            }
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        let directorySeed = await scanDirectoryCandidateSeed(rootURL: rootURL)
        var directoryCandidates = directorySeed.candidates
        var fileCandidates: [TextBoxMentionCandidate] = []
        var seenDirectoryRelativePaths = directorySeed.seenRelativePaths
        fileCandidates.reserveCapacity(min(maxIndexedFiles, 1024))

        func appendDirectoryCandidate(relativePath: String) {
            guard !relativePath.isEmpty,
                  directoryCandidates.count < maxIndexedDirectories,
                  seenDirectoryRelativePaths.insert(relativePath).inserted else {
                return
            }
            let directoryURL = rootURL
                .appendingPathComponent(relativePath, isDirectory: true)
                .standardizedFileURL
            directoryCandidates.append(TextBoxMentionCandidate.directoryCandidate(
                relativePath: relativePath,
                directoryURL: directoryURL
            ))
        }

        func appendDirectoryCandidates(containing relativePath: String) {
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
            guard components.count > 1 else { return }

            var currentPath = ""
            for component in components.dropLast() {
                let componentName = String(component)
                guard !directorySkipPolicy.shouldSkip(componentName) else { return }
                currentPath = currentPath.isEmpty ? componentName : "\(currentPath)/\(componentName)"
                appendDirectoryCandidate(relativePath: currentPath)
            }
        }

        func appendFileCandidate(relativePath: String) {
            guard !relativePath.isEmpty, fileCandidates.count < maxIndexedFiles else { return }
            appendDirectoryCandidates(containing: relativePath)
            let fileURL = rootURL.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
            let name = fileURL.lastPathComponent
            fileCandidates.append(TextBoxMentionCandidate.fileCandidate(
                relativePath: relativePath,
                fileURL: fileURL,
                fileName: name
            ))
        }

        var buffer = Data()
        let newline: UInt8 = 10
        do {
            for try await byte in stdout.fileHandleForReading.bytes {
                buffer.append(byte)
                guard byte == newline else { continue }

                let lineData = Data(buffer.dropLast())
                if let relativePath = String(data: lineData, encoding: .utf8) {
                    appendFileCandidate(relativePath: relativePath)
                }
                buffer.removeAll(keepingCapacity: true)
                if fileCandidates.count >= maxIndexedFiles {
                    break
                }
            }
        } catch {
            if process.isRunning {
                process.terminate()
            }
            _ = await terminationStatus.wait()
            return nil
        }

        let reachedLimit = fileCandidates.count >= maxIndexedFiles
        if reachedLimit, process.isRunning {
            process.terminate()
        } else if !buffer.isEmpty,
                  let relativePath = String(data: buffer, encoding: .utf8) {
            appendFileCandidate(relativePath: relativePath)
        }

        let status = await terminationStatus.wait()
        guard reachedLimit || status == 0 || status == 1 else {
            return nil
        }

        return TextBoxMentionCandidate.sortedFileSystemCandidates(directoryCandidates + fileCandidates)
    }

    private static func scanDirectoryCandidateSeed(
        rootURL: URL
    ) async -> (candidates: [TextBoxMentionCandidate], seenRelativePaths: Set<String>) {
        let fileManager = FileManager.default
        let rootPath = rootURL.standardizedFileURL.path
        let checksGitIgnore = await isGitWorkTree(rootURL: rootURL)
        var candidates: [TextBoxMentionCandidate] = []
        var seenRelativePaths = Set<String>()
        candidates.reserveCapacity(min(maxIndexedDirectories, 256))

        var directoryQueue = childDirectoryURLs(in: rootURL, fileManager: fileManager)
        var queueIndex = 0

        while queueIndex < directoryQueue.count, candidates.count < maxIndexedDirectories {
            let batchEndIndex = min(directoryQueue.count, queueIndex + directorySeedBatchSize)
            let directoryBatch = Array(directoryQueue[queueIndex..<batchEndIndex])
            queueIndex = batchEndIndex

            let relativePaths = directoryBatch.map {
                $0.path.pathRelative(toRoot: rootPath)
            }
            let ignoredRelativePaths = checksGitIgnore
                ? await gitIgnoredRelativePaths(rootURL: rootURL, relativePaths: relativePaths)
                : []

            for standardizedURL in directoryBatch {
                let relativePath = standardizedURL.path.pathRelative(toRoot: rootPath)
                guard !relativePath.isEmpty,
                      !ignoredRelativePaths.contains(relativePath),
                      !ignoredRelativePaths.contains("\(relativePath)/") else {
                    continue
                }

                if seenRelativePaths.insert(relativePath).inserted {
                    candidates.append(TextBoxMentionCandidate.directoryCandidate(
                        relativePath: relativePath,
                        directoryURL: standardizedURL
                    ))
                    if candidates.count >= maxIndexedDirectories {
                        break
                    }
                }

                directoryQueue.append(contentsOf: childDirectoryURLs(
                    in: standardizedURL,
                    fileManager: fileManager
                ))
            }
        }

        return (candidates, seenRelativePaths)
    }

    private static func childDirectoryURLs(in directoryURL: URL, fileManager: FileManager) -> [URL] {
        guard let children = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        return children
            .map(\.standardizedFileURL)
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true &&
                    !directorySkipPolicy.shouldSkip($0.lastPathComponent)
            }
    }

    private static func isGitWorkTree(rootURL: URL) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "git",
            "-C", rootURL.path,
            "rev-parse",
            "--is-inside-work-tree"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let terminationStatus = TextBoxProcessTerminationStatus()
        process.terminationHandler = { process in
            let status = process.terminationStatus
            Task {
                await terminationStatus.finish(status: status)
            }
        }

        do {
            try process.run()
        } catch {
            return false
        }
        return await terminationStatus.wait() == 0
    }

    private static func gitIgnoredRelativePaths(rootURL: URL, relativePaths: [String]) async -> Set<String> {
        guard !relativePaths.isEmpty else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "git",
            "-C", rootURL.path,
            "check-ignore",
            "--stdin"
        ]

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let terminationStatus = TextBoxProcessTerminationStatus()
        process.terminationHandler = { process in
            let status = process.terminationStatus
            Task {
                await terminationStatus.finish(status: status)
            }
        }

        do {
            try process.run()
        } catch {
            return []
        }
        let outputTask = Task<Data, Never> {
            var output = Data()
            do {
                for try await byte in stdout.fileHandleForReading.bytes {
                    output.append(byte)
                }
            } catch {
                return Data()
            }
            return output
        }

        let probePaths = relativePaths + relativePaths.map { "\($0)/" }
        let input = probePaths.joined(separator: "\n") + "\n"
        if let data = input.data(using: .utf8) {
            stdin.fileHandleForWriting.write(data)
        }
        stdin.fileHandleForWriting.closeFile()

        let output = await outputTask.value
        let status = await terminationStatus.wait()
        guard status == 0 || status == 1,
              let outputText = String(data: output, encoding: .utf8) else {
            return []
        }

        return Set(outputText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init))
    }

    private static func normalizedDirectory(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }

        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return url.path
    }
}

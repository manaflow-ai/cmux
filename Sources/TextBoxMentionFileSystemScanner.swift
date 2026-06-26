import CmuxFoundation
import Foundation

/// Scans a directory tree for `@`-mention file and directory candidates.
///
/// Prefers ripgrep (honoring `.gitignore` in a git work tree) and falls back to a
/// `FileManager` enumerator, applying a directory skip policy and bounded budgets
/// for indexed directories and files. A stateless, value-typed filesystem
/// capability whose configuration (skip policy, batch size, budgets) is injected
/// at construction; `TextBoxMentionIndexStore` holds one instance and drives it to
/// build its candidate index.
struct TextBoxMentionFileSystemScanner: Sendable {
    let directorySkipPolicy: IndexedDirectorySkipPolicy
    let directorySeedBatchSize: Int
    let maxIndexedDirectories: Int
    let maxIndexedFiles: Int
    let rootSuggestionLimit: Int

    init(
        directorySkipPolicy: IndexedDirectorySkipPolicy = IndexedDirectorySkipPolicy(),
        directorySeedBatchSize: Int = 128,
        maxIndexedDirectories: Int = 2000,
        maxIndexedFiles: Int = 6000,
        rootSuggestionLimit: Int = 200
    ) {
        self.directorySkipPolicy = directorySkipPolicy
        self.directorySeedBatchSize = directorySeedBatchSize
        self.maxIndexedDirectories = maxIndexedDirectories
        self.maxIndexedFiles = maxIndexedFiles
        self.rootSuggestionLimit = rootSuggestionLimit
    }

    func scanFiles(rootURL: URL) async -> [TextBoxMentionCandidate] {
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

    func scanRootFileSystemCandidates(rootURL: URL) async -> [TextBoxMentionCandidate] {
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

    func scanFilesWithRipgrep(rootURL: URL) async -> [TextBoxMentionCandidate]? {
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

    func scanDirectoryCandidateSeed(
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

    func childDirectoryURLs(in directoryURL: URL, fileManager: FileManager) -> [URL] {
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

    func isGitWorkTree(rootURL: URL) async -> Bool {
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

    func gitIgnoredRelativePaths(rootURL: URL, relativePaths: [String]) async -> Set<String> {
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
}

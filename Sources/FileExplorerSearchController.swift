import CmuxFoundation
import Darwin
import Foundation

struct FileSearchResult: Equatable, Sendable {
    let path: String
    let relativePath: String
    let lineNumber: Int
    let columnNumber: Int
    let preview: String
}

enum FileSearchRipgrepParser {
    static func parseMatchLine(_ line: String, rootPath: String) -> FileSearchResult? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "match",
              let payload = object["data"] as? [String: Any],
              let pathObject = payload["path"] as? [String: Any],
              let path = payloadString(from: pathObject),
              let linesObject = payload["lines"] as? [String: Any],
              let lineText = payloadString(from: linesObject),
              let lineNumber = payload["line_number"] as? Int else {
            return nil
        }

        let submatches = payload["submatches"] as? [[String: Any]]
        let firstStart = submatches?.first?["start"] as? Int
        let columnNumber = (firstStart ?? 0) + 1
        return FileSearchResult(
            path: path,
            relativePath: FileExplorerTerminalPathInsertion.relativePath(for: path, rootPath: rootPath),
            lineNumber: lineNumber,
            columnNumber: columnNumber,
            preview: lineText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func payloadString(from object: [String: Any]) -> String? {
        if let text = object["text"] as? String {
            return text
        }
        guard let encodedBytes = object["bytes"] as? String,
              let data = Data(base64Encoded: encodedBytes) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}

struct FileSearchSnapshot: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case idle
        case unsupported
        case searching
        case noMatches
        case matches
        case limited(Int)
        case failed(String)
    }

    var query: String
    var results: [FileSearchResult]
    var status: Status
    var isSearching: Bool

    static let empty = FileSearchSnapshot(query: "", results: [], status: .idle, isSearching: false)
}

enum FileExplorerSearchMessages {
    static func configuredRipgrepPathNotExecutable(_ path: String) -> String {
        String(
            format: String(
                localized: "fileExplorer.search.rgConfiguredPathNotExecutable",
                defaultValue: "Configured ripgrep path is not executable: %@"
            ),
            path
        )
    }
}

@MainActor
protocol FileSearchControlling: AnyObject {
    var onSnapshotChanged: ((FileSearchSnapshot) -> Void)? { get set }

    func search(query rawQuery: String, rootPath: String, isLocal: Bool, contentRevision: Int)
    func cancel(clear: Bool)
}

struct FileSearchPipelineUpdate: Sendable {
    let results: [FileSearchResult]
    let status: FileSearchSnapshot.Status
    let isSearching: Bool
    let shouldStopProcess: Bool
}

private actor FileSearchTerminationSignal {
    private var status: Int32?
    private var continuations: [UUID: CheckedContinuation<Int32?, Never>] = [:]
    private var cancelledWaits = Set<UUID>()

    func complete(status: Int32) {
        guard self.status == nil else { return }
        self.status = status
        let pendingContinuations = Array(continuations.values)
        continuations.removeAll()
        cancelledWaits.removeAll()
        for continuation in pendingContinuations {
            continuation.resume(returning: status)
        }
    }

    func wait() async -> Int32? {
        if let status {
            return status
        }
        let waitID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let status {
                    continuation.resume(returning: status)
                } else if cancelledWaits.remove(waitID) != nil {
                    continuation.resume(returning: nil)
                } else {
                    continuations[waitID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelWait(id: waitID)
            }
        }
    }

    private func cancelWait(id: UUID) {
        guard status == nil else { return }
        if let continuation = continuations.removeValue(forKey: id) {
            continuation.resume(returning: nil)
        } else {
            cancelledWaits.insert(id)
        }
    }
}

actor FileSearchOutputPipeline {
    private let rootPath: String
    private let maxResults: Int
    private let snapshotInterval: TimeInterval
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var results: [FileSearchResult] = []
    private var lastSnapshotEmissionDate = Date.distantPast
    private var isFinished = false
    private var terminalUpdate: FileSearchPipelineUpdate?

    init(rootPath: String, maxResults: Int, snapshotInterval: TimeInterval) {
        self.rootPath = rootPath
        self.maxResults = maxResults
        self.snapshotInterval = snapshotInterval
    }

    func consumeStdout(_ data: Data) -> FileSearchPipelineUpdate? {
        guard !isFinished else { return nil }
        stdoutBuffer.append(data)
        return consumeBufferedStdout(includeTrailingLine: false)
    }

    private func consumeBufferedStdout(includeTrailingLine: Bool) -> FileSearchPipelineUpdate? {
        var latestUpdate: FileSearchPipelineUpdate?
        while let newlineIndex = stdoutBuffer.firstIndex(of: 10) {
            let lineData = stdoutBuffer[..<newlineIndex]
            stdoutBuffer.removeSubrange(...newlineIndex)
            guard let update = consumeStdoutLine(lineData) else { continue }
            latestUpdate = update
            if update.shouldStopProcess {
                return update
            }
        }

        if includeTrailingLine, !stdoutBuffer.isEmpty {
            let lineData = stdoutBuffer
            stdoutBuffer.removeAll(keepingCapacity: true)
            if let update = consumeStdoutLine(lineData) {
                latestUpdate = update
            }
        }

        return latestUpdate
    }

    private func consumeStdoutLine(_ lineData: Data) -> FileSearchPipelineUpdate? {
        guard let line = String(data: lineData, encoding: .utf8),
              let result = FileSearchRipgrepParser.parseMatchLine(line, rootPath: rootPath) else {
            return nil
        }
        results.append(result)
        if results.count >= maxResults {
            let update = FileSearchPipelineUpdate(
                results: results,
                status: .limited(maxResults),
                isSearching: false,
                shouldStopProcess: true
            )
            isFinished = true
            terminalUpdate = update
            return update
        }

        let now = Date()
        guard now.timeIntervalSince(lastSnapshotEmissionDate) >= snapshotInterval else {
            return nil
        }
        lastSnapshotEmissionDate = now
        return FileSearchPipelineUpdate(
            results: results,
            status: .searching,
            isSearching: true,
            shouldStopProcess: false
        )
    }

    func consumeStderr(_ data: Data) {
        guard !isFinished else { return }
        stderrBuffer.append(data)
        if stderrBuffer.count > 8_192 {
            stderrBuffer.removeSubrange(0..<(stderrBuffer.count - 8_192))
        }
    }

    func consumeStderrLine(_ line: String) {
        guard !isFinished else { return }
        let lineData = Data((line + "\n").utf8)
        consumeStderr(lineData)
    }

    func finish(status: Int32) -> FileSearchPipelineUpdate {
        if let terminalUpdate {
            return terminalUpdate
        }
        let trailingUpdate: FileSearchPipelineUpdate?
        if !isFinished {
            trailingUpdate = consumeBufferedStdout(includeTrailingLine: true)
        } else {
            trailingUpdate = nil
        }
        if let trailingUpdate, trailingUpdate.shouldStopProcess {
            return trailingUpdate
        }
        isFinished = true
        if status == 0 || status == 1 {
            return FileSearchPipelineUpdate(
                results: results,
                status: results.isEmpty ? .noMatches : .matches,
                isSearching: false,
                shouldStopProcess: false
            )
        }

        let errorText = String(data: stderrBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = String(
            format: String(localized: "fileExplorer.search.rgExited", defaultValue: "rg exited with status %d"),
            Int(status)
        )
        return FileSearchPipelineUpdate(
            results: results,
            status: .failed(errorText?.isEmpty == false ? errorText! : fallback),
            isSearching: false,
            shouldStopProcess: false
        )
    }
}

private final class FileSearchReadHandle: @unchecked Sendable {
    private let fileHandle: FileHandle

    init(_ fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    var fileDescriptor: Int32 {
        fileHandle.fileDescriptor
    }
}

private enum FileSearchPipeReadResult: Sendable {
    case chunk(Data)
    case endOfFile
    case failure(Int32)
}

private enum FileSearchPipeReader {
    private static let queue = DispatchQueue(
        label: "com.cmux.file-search.pipe-read",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func read(from readHandle: FileSearchReadHandle, maxByteCount: Int) async -> FileSearchPipeReadResult {
        await withCheckedContinuation { continuation in
            queue.async {
                var buffer = [UInt8](repeating: 0, count: maxByteCount)
                let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                    // Keep blocking pipe reads off Swift's cooperative executor.
                    Darwin.read(readHandle.fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
                }
                if bytesRead > 0 {
                    continuation.resume(returning: .chunk(Data(buffer.prefix(bytesRead))))
                } else if bytesRead == 0 {
                    continuation.resume(returning: .endOfFile)
                } else {
                    continuation.resume(returning: .failure(errno))
                }
            }
        }
    }
}

@MainActor
final class FileSearchController: FileSearchControlling {
    private struct Request: Equatable {
        let query: String
        let rootPath: String
        let isLocal: Bool
        let contentRevision: Int
    }

    var onSnapshotChanged: ((FileSearchSnapshot) -> Void)?

    private let maxResults = 500
    private let snapshotInterval: TimeInterval = 0.05
    private let excludedSearchGlobs = [
        "!.git/**",
        "!**/.git/**",
        "!node_modules/**",
        "!**/node_modules/**",
        "!dist/**",
        "!**/dist/**",
        "!build/**",
        "!**/build/**",
        "!DerivedData/**",
        "!**/DerivedData/**",
    ]
    private var process: Process?
    private var generation = 0
    private var request: Request?
    private var results: [FileSearchResult] = []
    private var pipeline: FileSearchOutputPipeline?
    private var searchTask: Task<Void, Never>?

    func search(query rawQuery: String, rootPath: String, isLocal: Bool, contentRevision: Int = 0) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextRequest = Request(
            query: query,
            rootPath: rootPath,
            isLocal: isLocal,
            contentRevision: contentRevision
        )
        if nextRequest == request, process?.isRunning == true {
            return
        }
        request = nextRequest

        stopAndAdvanceGeneration()
        results.removeAll()

        guard !query.isEmpty else {
            emit(status: .idle, isSearching: false)
            return
        }
        guard isLocal else {
            emit(status: .unsupported, isSearching: false)
            return
        }
        guard !rootPath.isEmpty else {
            emit(status: .noMatches, isSearching: false)
            return
        }
        let resolution = RipgrepExecutableResolver().resolution()
        let executable: FileSearchRipgrepExecutable
        switch resolution {
        case .found(let resolvedExecutable):
            executable = resolvedExecutable
        case .configuredPathNotExecutable(let path):
            emit(
                status: .failed(FileExplorerSearchMessages.configuredRipgrepPathNotExecutable(path)),
                isSearching: false
            )
            return
        case .notFound:
            emit(
                status: .failed(String(localized: "fileExplorer.search.rgNotInstalled", defaultValue: "ripgrep (rg) is not installed or is not on PATH.")),
                isSearching: false
            )
            return
        }

        generation += 1
        let searchGeneration = generation
        emit(status: .searching, isSearching: true)

        let process = Process()
        process.executableURL = executable.url
        process.arguments = executable.prefixArguments + [
            "--json",
            "--line-number",
            "--column",
            "--smart-case",
            "--fixed-strings",
            "--max-columns", "300",
            "--max-columns-preview",
            "--color", "never",
            "--hidden",
        ] + excludedSearchGlobs.flatMap { ["--glob", $0] } + [
            "--",
            query,
            rootPath,
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let pipeline = FileSearchOutputPipeline(
            rootPath: rootPath,
            maxResults: maxResults,
            snapshotInterval: snapshotInterval
        )
        self.pipeline = pipeline
        let terminationSignal = FileSearchTerminationSignal()

        process.terminationHandler = { process in
            let status = process.terminationStatus
            Task {
                await terminationSignal.complete(status: status)
            }
        }

        do {
            try process.run()
            self.process = process
            let stdoutReadHandle = FileSearchReadHandle(stdout.fileHandleForReading)
            let stderrReadHandle = FileSearchReadHandle(stderr.fileHandleForReading)
            searchTask = Task.detached(priority: .userInitiated) { [weak self, pipeline, terminationSignal, stdoutReadHandle, stderrReadHandle] in
                // Result completeness is defined by stdout. Stderr stays diagnostic-only:
                // successful searches do not wait on it, failed searches do before formatting the error.
                let stderrTask = Task.detached(priority: .utility) { [stderrReadHandle, pipeline] in
                    await Self.streamStderr(from: stderrReadHandle, pipeline: pipeline)
                }
                let applyUpdate: @Sendable (FileSearchPipelineUpdate, Int) async -> Void = { [weak self] update, generation in
                    await self?.applyPipelineUpdate(update, generation: generation)
                }
                let stdoutTask = Task.detached(priority: .userInitiated) { [stdoutReadHandle, pipeline, searchGeneration, applyUpdate] in
                    await Self.streamStdout(
                        from: stdoutReadHandle,
                        pipeline: pipeline,
                        generation: searchGeneration,
                        applyUpdate: applyUpdate
                    )
                }
                defer {
                    stderrTask.cancel()
                    stdoutTask.cancel()
                }
                guard let status = await terminationSignal.wait() else { return }
                await stdoutTask.value
                guard !Task.isCancelled else { return }
                if status != 0 && status != 1 {
                    await stderrTask.value
                }
                let update = await pipeline.finish(status: status)
                await self?.finish(generation: searchGeneration, update: update)
            }
        } catch {
            process.standardOutput = nil
            process.standardError = nil
            self.pipeline = nil
            emit(status: .failed(error.localizedDescription), isSearching: false)
        }
    }

    func cancel(clear: Bool) {
        request = nil
        stopAndAdvanceGeneration()
        if clear {
            results.removeAll()
            emit(status: .idle, isSearching: false)
        }
    }

    private func applyPipelineUpdate(_ update: FileSearchPipelineUpdate, generation searchGeneration: Int) {
        guard searchGeneration == generation else { return }
        results = update.results
        if update.shouldStopProcess {
            stopAndAdvanceGeneration()
        }
        emit(status: update.status, isSearching: update.isSearching)
    }

    private func finish(generation searchGeneration: Int, update: FileSearchPipelineUpdate) {
        guard searchGeneration == generation else { return }
        process = nil
        pipeline = nil
        searchTask = nil
        results = update.results
        emit(status: update.status, isSearching: update.isSearching)
    }

    private func emit(status: FileSearchSnapshot.Status, isSearching: Bool) {
        onSnapshotChanged?(FileSearchSnapshot(
            query: request?.query ?? "",
            results: results,
            status: status,
            isSearching: isSearching
        ))
    }

    private func stopAndAdvanceGeneration() {
        generation += 1
        stopCurrentProcess()
    }

    private func stopCurrentProcess() {
        guard let process else { return }
        self.process = nil
        searchTask?.cancel()
        searchTask = nil
        pipeline = nil
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGTERM)
        }
    }

    private nonisolated static func streamStdout(
        from readHandle: FileSearchReadHandle,
        pipeline: FileSearchOutputPipeline,
        generation: Int,
        applyUpdate: @Sendable (FileSearchPipelineUpdate, Int) async -> Void
    ) async {
        while !Task.isCancelled {
            let readResult = await FileSearchPipeReader.read(from: readHandle, maxByteCount: 32 * 1024)
            guard !Task.isCancelled else { return }
            switch readResult {
            case .chunk(let data):
                guard let update = await pipeline.consumeStdout(data) else { continue }
                await applyUpdate(update, generation)
                if update.shouldStopProcess { return }
            case .endOfFile:
                return
            case .failure(let errorNumber) where errorNumber == EINTR:
                continue
            case .failure(let errorNumber):
                await pipeline.consumeStderrLine(String(cString: strerror(errorNumber)))
                return
            }
        }
    }

    private nonisolated static func streamStderr(
        from readHandle: FileSearchReadHandle,
        pipeline: FileSearchOutputPipeline
    ) async {
        while !Task.isCancelled {
            let readResult = await FileSearchPipeReader.read(from: readHandle, maxByteCount: 8 * 1024)
            guard !Task.isCancelled else { return }
            switch readResult {
            case .chunk(let data):
                await pipeline.consumeStderr(data)
            case .endOfFile:
                return
            case .failure(let errorNumber) where errorNumber == EINTR:
                continue
            case .failure(let errorNumber):
                await pipeline.consumeStderrLine(String(cString: strerror(errorNumber)))
                return
            }
        }
    }

}

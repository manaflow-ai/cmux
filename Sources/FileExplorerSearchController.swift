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

@MainActor
protocol FileSearchControlling: AnyObject {
    var onSnapshotChanged: ((FileSearchSnapshot) -> Void)? { get set }

    func search(query rawQuery: String, rootPath: String, isLocal: Bool, contentRevision: Int)
    func cancel(clear: Bool)
}

private struct FileSearchPipelineUpdate: Sendable {
    let results: [FileSearchResult]
    let status: FileSearchSnapshot.Status
    let isSearching: Bool
    let shouldStopProcess: Bool
}

private actor FileSearchOutputPipeline {
    private let rootPath: String
    private let maxResults: Int
    private let snapshotInterval: TimeInterval
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var results: [FileSearchResult] = []
    private var lastSnapshotEmissionDate = Date.distantPast

    init(rootPath: String, maxResults: Int, snapshotInterval: TimeInterval) {
        self.rootPath = rootPath
        self.maxResults = maxResults
        self.snapshotInterval = snapshotInterval
    }

    func consumeStdout(_ data: Data) -> FileSearchPipelineUpdate? {
        stdoutBuffer.append(data)
        var didAppendResult = false

        while let newlineIndex = stdoutBuffer.firstIndex(of: 10) {
            let lineData = stdoutBuffer[..<newlineIndex]
            stdoutBuffer.removeSubrange(...newlineIndex)
            guard let line = String(data: lineData, encoding: .utf8),
                  let result = FileSearchRipgrepParser.parseMatchLine(line, rootPath: rootPath) else {
                continue
            }
            results.append(result)
            didAppendResult = true
            if results.count >= maxResults {
                return FileSearchPipelineUpdate(
                    results: results,
                    status: .limited(maxResults),
                    isSearching: false,
                    shouldStopProcess: true
                )
            }
        }

        guard didAppendResult else { return nil }
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
        stderrBuffer.append(data)
        if stderrBuffer.count > 8_192 {
            stderrBuffer.removeSubrange(0..<(stderrBuffer.count - 8_192))
        }
    }

    func finish(status: Int32) -> FileSearchPipelineUpdate {
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

@MainActor
final class FileSearchController: FileSearchControlling {
    private struct Request: Equatable {
        let query: String
        let rootPath: String
        let isLocal: Bool
        let contentRevision: Int
    }

    private struct RipgrepExecutable {
        let url: URL
        let prefixArguments: [String]
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
        guard let executable = Self.ripgrepExecutable() else {
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

        stdout.fileHandleForReading.readabilityHandler = { [weak self, pipeline] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { [weak self, pipeline] in
                guard let update = await pipeline.consumeStdout(data) else { return }
                await self?.applyPipelineUpdate(update, generation: searchGeneration)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [pipeline] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { [pipeline] in
                await pipeline.consumeStderr(data)
            }
        }

        process.terminationHandler = { [weak self, pipeline] process in
            Task { [weak self, pipeline] in
                let update = await pipeline.finish(status: process.terminationStatus)
                await self?.finish(generation: searchGeneration, update: update)
            }
        }

        do {
            try process.run()
            self.process = process
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
        stopCurrentProcess()
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
        pipeline = nil
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        if process.isRunning {
            Task.detached(priority: .utility) {
                process.terminate()
            }
        }
    }

    private static func ripgrepExecutable() -> RipgrepExecutable? {
        let fileManager = FileManager.default
        for path in ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg"] where fileManager.isExecutableFile(atPath: path) {
            return RipgrepExecutable(url: URL(fileURLWithPath: path), prefixArguments: [])
        }
        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":", omittingEmptySubsequences: true) {
            let path = URL(fileURLWithPath: String(directory)).appendingPathComponent("rg").path
            if fileManager.isExecutableFile(atPath: path) {
                return RipgrepExecutable(url: URL(fileURLWithPath: path), prefixArguments: [])
            }
        }
        return nil
    }
}

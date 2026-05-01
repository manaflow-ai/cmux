import Foundation

struct FileSearchResult: Equatable {
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
            relativePath: relativePath(for: path, rootPath: rootPath),
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

    private static func relativePath(for path: String, rootPath: String) -> String {
        guard !rootPath.isEmpty else { return path }
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let standardizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        guard standardizedPath.hasPrefix(standardizedRoot) else { return path }
        var relative = String(standardizedPath.dropFirst(standardizedRoot.count))
        if relative.hasPrefix("/") {
            relative.removeFirst()
        }
        return relative.isEmpty ? (path as NSString).lastPathComponent : relative
    }
}

struct FileSearchSnapshot: Equatable {
    enum Status: Equatable {
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
final class FileSearchController {
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
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var generation = 0
    private var request: Request?
    private var results: [FileSearchResult] = []

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
        stdoutBuffer.removeAll(keepingCapacity: true)
        stderrBuffer.removeAll(keepingCapacity: true)

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

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.consumeStdout(data, generation: searchGeneration, rootPath: rootPath)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.consumeStderr(data, generation: searchGeneration)
            }
        }

        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.finish(generation: searchGeneration, status: process.terminationStatus)
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            process.standardOutput = nil
            process.standardError = nil
            emit(status: .failed(error.localizedDescription), isSearching: false)
        }
    }

    func cancel(clear: Bool) {
        request = nil
        stopAndAdvanceGeneration()
        stdoutBuffer.removeAll(keepingCapacity: true)
        stderrBuffer.removeAll(keepingCapacity: true)
        if clear {
            results.removeAll()
            emit(status: .idle, isSearching: false)
        }
    }

    private func consumeStdout(_ data: Data, generation searchGeneration: Int, rootPath: String) {
        guard searchGeneration == generation else { return }
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
                stopAndAdvanceGeneration()
                emit(status: .limited(maxResults), isSearching: false)
                return
            }
        }
        if didAppendResult {
            emit(status: .searching, isSearching: true)
        }
    }

    private func consumeStderr(_ data: Data, generation searchGeneration: Int) {
        guard searchGeneration == generation else { return }
        stderrBuffer.append(data)
        if stderrBuffer.count > 8_192 {
            stderrBuffer.removeSubrange(0..<(stderrBuffer.count - 8_192))
        }
    }

    private func finish(generation searchGeneration: Int, status: Int32) {
        guard searchGeneration == generation else { return }
        stopCurrentProcess()

        if status == 0 || status == 1 {
            let finalStatus: FileSearchSnapshot.Status = results.isEmpty ? .noMatches : .matches
            emit(status: finalStatus, isSearching: false)
            return
        }

        let errorText = String(data: stderrBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = String(
            format: String(localized: "fileExplorer.search.rgExited", defaultValue: "rg exited with status %d"),
            Int(status)
        )
        emit(status: .failed(errorText?.isEmpty == false ? errorText! : fallback), isSearching: false)
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
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        if process.isRunning {
            process.terminate()
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

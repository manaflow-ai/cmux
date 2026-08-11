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
        case failed(String)
    }

    var query: String
    var results: [FileSearchResult]
    var status: Status
    var isSearching: Bool
    // True when more buffered or in-flight results can be displayed.
    var hasMore: Bool = false
    /// Total matches buffered by the controller, including undisplayed pages.
    var totalMatchCount: Int = 0
    /// True when the search stopped at the hard result cap.
    var isTruncated: Bool = false

    static let empty = FileSearchSnapshot(
        query: "",
        results: [],
        status: .idle,
        isSearching: false,
        hasMore: false,
        totalMatchCount: 0,
        isTruncated: false
    )
}

struct FileSearchOptions: Equatable, Sendable {
    var matchCase: Bool = false
    var codeOnly: Bool = false

    static let `default` = FileSearchOptions()
}

enum RipgrepIntegrationSettings {
    static let customRipgrepPathKey = "ripgrepCustomBinaryPath"

    static func rawCustomRipgrepPath(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: customRipgrepPathKey)
    }

    static func normalizedCustomPath(_ rawPath: String?, homeDirectory: String = NSHomeDirectory()) -> String? {
        let trimmed = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }

        if trimmed == "~" {
            return (homeDirectory as NSString).standardizingPath
        }
        if trimmed.hasPrefix("~/") {
            let home = (homeDirectory as NSString).standardizingPath
            let relativePath = String(trimmed.dropFirst(2))
            return (home as NSString).appendingPathComponent(relativePath)
        }
        return trimmed
    }
}

struct FileSearchRipgrepExecutable: Equatable, Sendable {
    let url: URL
    let prefixArguments: [String]
}

enum RipgrepExecutableResolution: Equatable, Sendable {
    case found(FileSearchRipgrepExecutable)
    case configuredPathNotExecutable(String)
    case notFound
}

enum RipgrepExecutableResolver {
    static func resolve(
        configuredPath: String? = RipgrepIntegrationSettings.rawCustomRipgrepPath(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userName: String = NSUserName(),
        homeDirectory: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> FileSearchRipgrepExecutable? {
        guard case .found(let executable) = resolution(
            configuredPath: configuredPath,
            environment: environment,
            userName: userName,
            homeDirectory: homeDirectory,
            isExecutable: isExecutable
        ) else {
            return nil
        }
        return executable
    }

    static func resolution(
        configuredPath: String? = RipgrepIntegrationSettings.rawCustomRipgrepPath(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userName: String = NSUserName(),
        homeDirectory: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> RipgrepExecutableResolution {
        if let configuredPath = RipgrepIntegrationSettings.normalizedCustomPath(
            configuredPath,
            homeDirectory: homeDirectory
        ) {
            if isExecutable(configuredPath) {
                return .found(FileSearchRipgrepExecutable(url: URL(fileURLWithPath: configuredPath), prefixArguments: []))
            }
            return .configuredPathNotExecutable(configuredPath)
        }

        for path in defaultSearchPaths(userName: userName, homeDirectory: homeDirectory) where isExecutable(path) {
            return .found(FileSearchRipgrepExecutable(url: URL(fileURLWithPath: path), prefixArguments: []))
        }

        let pathValue = environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":", omittingEmptySubsequences: true) {
            let path = URL(fileURLWithPath: String(directory)).appendingPathComponent("rg").path
            if isExecutable(path) {
                return .found(FileSearchRipgrepExecutable(url: URL(fileURLWithPath: path), prefixArguments: []))
            }
        }
        return .notFound
    }

    private static func defaultSearchPaths(userName: String, homeDirectory: String) -> [String] {
        let homeDirectory = (homeDirectory as NSString).standardizingPath
        return [
            "/opt/homebrew/bin/rg",
            "/usr/local/bin/rg",
            "/opt/local/bin/rg",
            "/usr/bin/rg",
            "/etc/profiles/per-user/\(userName)/bin/rg",
            "/run/current-system/sw/bin/rg",
            "/nix/var/nix/profiles/default/bin/rg",
            "\(homeDirectory)/.nix-profile/bin/rg",
            "/nix/var/nix/profiles/per-user/\(userName)/profile/bin/rg",
        ]
    }
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

    func search(query rawQuery: String, rootPath: String, isLocal: Bool, contentRevision: Int, options: FileSearchOptions)
    func cancel(clear: Bool)
    // scroll-triggered "load next page" hook for the grouped Find view.
    // Idempotent: extra calls when nothing new is buffered are no-ops.
    func loadMore()
}

struct FileSearchPipelineUpdate: Sendable {
    let results: [FileSearchResult]
    let status: FileSearchSnapshot.Status
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
    private let hardMaxResults: Int
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var results: [FileSearchResult] = []
    private var isFinished = false
    private var terminalUpdate: FileSearchPipelineUpdate?
    // pagination, the pipeline buffers up to `hardMaxResults` results
    // but only emits a settled `.matches` snapshot to the controller when the
    // buffer first reaches `pendingEmissionTarget`. Initial target = the first
    // page size; subsequent targets are bumped by the controller from
    // `requestNextEmission` in response to user scroll. Once a target is hit
    // the field is cleared until the next request, this is what suppresses
    // the previous interval-based intermediate-snapshot flicker.
    private var pendingEmissionTarget: Int?
    // gate for the early-paint branch, once any pre-finish emit has
    // been delivered, suppress further early paints. Every emit becomes a
    // MainActor hop + NSOutlineView diff, so capping pre-finish emits at one
    // keeps the main thread free for input under heavy `rg`s.
    private var hasDeliveredInitialEmit = false

    init(rootPath: String, hardMaxResults: Int, initialEmissionTarget: Int) {
        self.rootPath = rootPath
        self.hardMaxResults = hardMaxResults
        self.pendingEmissionTarget = initialEmissionTarget
    }

    func consumeStdout(_ data: Data) -> FileSearchPipelineUpdate? {
        guard !isFinished else { return nil }
        stdoutBuffer.append(data)
        return consumeBufferedStdout(includeTrailingLine: false)
    }

    /// Asks the pipeline to emit a settled `.matches` update once the buffer
    /// reaches `targetCount` results (or immediately, if it's already there).
    /// Returning a non-nil update means the controller should apply it now.
    func requestNextEmission(targetCount: Int) -> FileSearchPipelineUpdate? {
        guard !isFinished else { return nil }
        let clampedTarget = min(targetCount, hardMaxResults)
        if results.count >= clampedTarget {
            pendingEmissionTarget = nil
            return matchesUpdate(shouldStopProcess: false)
        }
        pendingEmissionTarget = clampedTarget
        return nil
    }

    private func consumeBufferedStdout(includeTrailingLine: Bool) -> FileSearchPipelineUpdate? {
        let resultsCountBefore = results.count
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

        // one-shot early paint so sparse queries don't wait on rg's
        // full tree walk. Clearing `pendingEmissionTarget` here makes the
        // target-met branch in `consumeStdoutLine` a no-op for the rest of
        // the query (loadMore can re-arm it explicitly); together with
        // `hasDeliveredInitialEmit` this caps pre-finish emits at one.
        if latestUpdate == nil,
           !isFinished,
           !hasDeliveredInitialEmit,
           results.count > resultsCountBefore {
            hasDeliveredInitialEmit = true
            pendingEmissionTarget = nil
            latestUpdate = matchesUpdate(shouldStopProcess: false)
        }

        return latestUpdate
    }

    private func consumeStdoutLine(_ lineData: Data) -> FileSearchPipelineUpdate? {
        guard let line = String(data: lineData, encoding: .utf8),
              let result = FileSearchRipgrepParser.parseMatchLine(line, rootPath: rootPath) else {
            return nil
        }
        results.append(result)
        if results.count >= hardMaxResults {
            let update = matchesUpdate(shouldStopProcess: true)
            isFinished = true
            terminalUpdate = update
            hasDeliveredInitialEmit = true
            return update
        }
        if let target = pendingEmissionTarget, results.count >= target {
            pendingEmissionTarget = nil
            hasDeliveredInitialEmit = true
            return matchesUpdate(shouldStopProcess: false)
        }
        return nil
    }

    private func matchesUpdate(shouldStopProcess: Bool) -> FileSearchPipelineUpdate {
        FileSearchPipelineUpdate(
            results: results,
            status: results.isEmpty ? .noMatches : .matches,
            shouldStopProcess: shouldStopProcess
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
        let options: FileSearchOptions
    }

    var onSnapshotChanged: ((FileSearchSnapshot) -> Void)?

    // paginated Find, first chunk shown ASAP, more loaded on scroll
    // up to the hard cap. Initial page is small so the user sees results within
    // a frame of ripgrep producing them; the cap protects model + UI from
    // unbounded queries.
    private let pageSize = 100
    private let hardMaxResults = 5000
    // Config/data files (json, yaml, toml, markdown, lock) are intentionally excluded.
    private static let codeTypeDefinition = "code:*.{" + [
        "c", "h", "cc", "cpp", "cxx", "hpp", "hxx",
        "m", "mm",
        "swift",
        "go",
        "rs",
        "py", "pyi", "pyx",
        "rb",
        "php",
        "java", "kt", "kts", "scala", "groovy", "clj", "cljs", "cljc",
        "js", "mjs", "cjs", "jsx", "ts", "tsx", "vue", "svelte",
        "dart",
        "lua",
        "pl", "pm",
        "r",
        "sh", "bash", "zsh", "fish",
        "ps1",
        "sql",
        "ex", "exs", "erl", "hrl",
        "hs", "lhs",
        "ml", "mli", "fs", "fsx", "fsi",
        "vb", "cs",
        "nim", "zig", "v", "sv",
        "sol",
        "elm",
        "jl",
        "asm", "s", "S",
        "html", "htm", "xhtml", "css", "scss", "sass", "less",
        "wat", "wgsl", "metal", "glsl", "frag", "vert",
        "proto", "thrift",
        "tf",
        "gradle",
        "make", "mk",
    ].joined(separator: ",") + "}"
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
    // append-only "what's currently rendered" view of `results`. Each
    // page boundary re-ranks ONLY the new tail and appends, earlier rows stay
    // in place so scroll position never jumps. `displayedResults.count` is the
    // cursor into `results` for the next page.
    private var displayedResults: [FileSearchResult] = []
    private var pipeline: FileSearchOutputPipeline?
    private var searchTask: Task<Void, Never>?

    // main-thread coalescing slot. Multiple pipeline updates can arrive
    // close together (e.g. early-streaming emit immediately followed by the
    // hard-cap or finish emit when `rg` is fast); without a coalesce step they
    // each queue an independent MainActor hop and each runs the full
    // grouping + NSOutlineView diff + group `expandItem` walk in
    // `FileExplorerSearchResultsView.apply`. Under heavy queries this saturated the
    // main thread and blocked search-bar / terminal-panel input. With the
    // slot, any update arriving while a drain is pending overwrites the slot
    //, only the latest one ever reaches `applyPipelineUpdate`.
    private var pendingPipelineUpdate: (update: FileSearchPipelineUpdate, generation: Int)?
    private var pendingPipelineDrainScheduled = false
    private var isSearchRunning = false
    private var didHitHardCap = false

#if DEBUG
    private(set) var debugPipelineDeliveryCount = 0

    func debugEnqueuePipelineUpdate(_ update: FileSearchPipelineUpdate) {
        enqueuePipelineUpdate(update, generation: generation)
    }
#endif

    func search(query rawQuery: String, rootPath: String, isLocal: Bool, contentRevision: Int = 0, options: FileSearchOptions = .default) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextRequest = Request(
            query: query,
            rootPath: rootPath,
            isLocal: isLocal,
            contentRevision: contentRevision,
            options: options
        )
        if nextRequest == request, process?.isRunning == true {
            return
        }
        request = nextRequest

        stopAndAdvanceGeneration()
        results.removeAll()
        displayedResults.removeAll()
        didHitHardCap = false

        guard !query.isEmpty else {
            emit(status: .idle)
            return
        }
        guard isLocal else {
            emit(status: .unsupported)
            return
        }
        guard !rootPath.isEmpty else {
            emit(status: .noMatches)
            return
        }
        let resolution = RipgrepExecutableResolver.resolution()
        let executable: FileSearchRipgrepExecutable
        switch resolution {
        case .found(let resolvedExecutable):
            executable = resolvedExecutable
        case .configuredPathNotExecutable(let path):
            emit(status: .failed(FileExplorerSearchMessages.configuredRipgrepPathNotExecutable(path)))
            return
        case .notFound:
            emit(status: .failed(String(localized: "fileExplorer.search.rgNotInstalled", defaultValue: "ripgrep (rg) is not installed or is not on PATH.")))
            return
        }

        generation += 1
        let searchGeneration = generation
        isSearchRunning = true
        emit(status: .searching)

        let caseFlag = options.matchCase ? "--case-sensitive" : "--ignore-case"
        let codeOnlyArgs: [String] = options.codeOnly
            ? ["--type-add", Self.codeTypeDefinition, "--type", "code"]
            : []

        let process = Process()
        process.executableURL = executable.url
        process.arguments = executable.prefixArguments + [
            "--json",
            "--line-number",
            "--column",
            caseFlag,
            "--fixed-strings",
            "--max-columns", "300",
            "--max-columns-preview",
            "--color", "never",
            "--hidden",
        ] + codeOnlyArgs + excludedSearchGlobs.flatMap { ["--glob", $0] } + [
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
            hardMaxResults: hardMaxResults,
            initialEmissionTarget: pageSize
        )
        self.pipeline = pipeline
        let terminationSignal = FileSearchTerminationSignal()

        process.terminationHandler = { process in
            let status = process.terminationStatus
            Task {
                await terminationSignal.complete(status: status)
            }
        }

        let stdoutReadHandle = FileSearchReadHandle(stdout.fileHandleForReading)
        let stderrReadHandle = FileSearchReadHandle(stderr.fileHandleForReading)
        // process.run() takes several ms doing fork/exec/pipe setup.
        // Doing it inline on @MainActor was visible as typing lag on every
        // keystroke; the detached task handles spawn, stdout/stderr drains,
        // and termination off-main. Only the resulting applyUpdate hops
        // back to main.
        let task = Task.detached(priority: .userInitiated) { [weak self, pipeline, terminationSignal, process, stdoutReadHandle, stderrReadHandle] in
            do {
                try process.run()
            } catch {
                let message = error.localizedDescription
                await MainActor.run { [weak self] in
                    guard let self, self.generation == searchGeneration else { return }
                    self.pipeline = nil
                    self.process = nil
                    self.isSearchRunning = false
                    self.emit(status: .failed(message))
                }
                return
            }
            // Cancellation that arrived while spawning couldn't SIGTERM a
            // not-yet-running process; do it ourselves now and bail.
            // Also stash the running process on main so a subsequent
            // cancel() can find it.
            let stillCurrent = await MainActor.run { [weak self] () -> Bool in
                guard let self, self.generation == searchGeneration else { return false }
                self.process = process
                return true
            }
            if !stillCurrent {
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGTERM)
                }
                return
            }
            // Result completeness is defined by stdout. Stderr stays diagnostic-only:
            // successful searches do not wait on it, failed searches do before formatting the error.
            let stderrTask = Task.detached(priority: .utility) { [stderrReadHandle, pipeline] in
                await Self.streamStderr(from: stderrReadHandle, pipeline: pipeline)
            }
            let applyUpdate: @Sendable (FileSearchPipelineUpdate, Int) async -> Void = { [weak self] update, generation in
                await self?.enqueuePipelineUpdate(update, generation: generation)
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
        searchTask = task
    }

    func cancel(clear: Bool) {
        request = nil
        stopAndAdvanceGeneration()
        didHitHardCap = false
        if clear {
            results.removeAll()
            displayedResults.removeAll()
            emit(status: .idle)
        }
    }

    func loadMore() {
        // Drop stale scroll-triggered loadMore after cancel(clear:false), else
        // we'd re-emit the previous query's buffered results under empty query.
        guard request != nil else { return }
        guard displayedResults.count < hardMaxResults else { return }
        // Fast path: pipeline already buffered more than we've shown (hardMax
        // burst or post-finish() drain). Drain a page locally instead of
        // round-tripping the actor.
        if results.count > displayedResults.count {
            appendNewlyBufferedToDisplay()
            emit(status: settledStatus(forFallback: .matches))
            return
        }
        guard let pipeline else { return }
        let target = min(displayedResults.count + pageSize, hardMaxResults)
        let searchGeneration = generation
        Task { [weak self] in
            guard let update = await pipeline.requestNextEmission(targetCount: target) else { return }
            self?.applyPipelineUpdate(update, generation: searchGeneration)
        }
    }

    /// Coalescing entry point for streaming updates from the pipeline. Stores
    /// the latest update in `pendingPipelineUpdate` and schedules a single
    /// drain Task. If a drain is already scheduled, this is a no-op beyond
    /// overwriting the slot.
    ///
    /// terminal updates (`shouldStopProcess == true`) skip coalescing
    /// and are applied immediately, they carry the "stop the rg" signal and
    /// must take effect synchronously, and they're also the last update of a
    /// query so there's nothing to coalesce them against.
    private func enqueuePipelineUpdate(_ update: FileSearchPipelineUpdate, generation searchGeneration: Int) {
        guard searchGeneration == generation else { return }
        if update.shouldStopProcess {
            pendingPipelineUpdate = nil
            applyPipelineUpdate(update, generation: searchGeneration)
            return
        }
        pendingPipelineUpdate = (update, searchGeneration)
        guard !pendingPipelineDrainScheduled else { return }
        pendingPipelineDrainScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingPipelineDrainScheduled = false
            guard let pending = self.pendingPipelineUpdate else { return }
            self.pendingPipelineUpdate = nil
            self.applyPipelineUpdate(pending.update, generation: pending.generation)
        }
    }

    private func applyPipelineUpdate(_ update: FileSearchPipelineUpdate, generation searchGeneration: Int) {
        guard searchGeneration == generation else { return }
#if DEBUG
        debugPipelineDeliveryCount += 1
#endif
        results = update.results
        if update.shouldStopProcess {
            didHitHardCap = true
            stopAndAdvanceGeneration()
        }
        appendNewlyBufferedToDisplay()
        emit(status: settledStatus(forFallback: update.status))
    }

    private func finish(generation searchGeneration: Int, update: FileSearchPipelineUpdate) {
        guard searchGeneration == generation else { return }
        pendingPipelineUpdate = nil
        process = nil
        pipeline = nil
        searchTask = nil
        results = update.results
        appendNewlyBufferedToDisplay()
        isSearchRunning = false
        emit(status: settledStatus(forFallback: update.status))
    }

    /// Re-rank the next `pageSize` slice of `results` past `displayedResults`
    /// and append. Earlier display order stays frozen so the user's scroll
    /// position never jumps; ranking quality therefore drops across page
    /// boundaries (a tier-0 basename match in page 2 cannot bubble above a
    /// tier-2 hit in page 1), the deliberate trade-off vs full-buffer re-rank.
    private func appendNewlyBufferedToDisplay() {
        let start = displayedResults.count
        guard start < results.count else { return }
        // cap each appended chunk at `pageSize`. A single pipeline
        // emission can carry far more than a page (the hard-cap stop can hand
        // us up to 5000 rows at once, or `finish()` drains trailing buffered
        // rows beyond what the user has scrolled to). Leftovers surface via
        // subsequent `loadMore` calls without going back to rg.
        let endIndex = min(start + pageSize, results.count)
        let newChunk = Array(results[start..<endIndex])
        let query = request?.query ?? ""
        let rankedChunk = FileSearchRanking.apply(to: newChunk, query: query)
        displayedResults.append(contentsOf: rankedChunk)
    }

    private func settledStatus(forFallback fallback: FileSearchSnapshot.Status) -> FileSearchSnapshot.Status {
        // Pipeline-derived `.failed` / `.unsupported` pass through unchanged.
        switch fallback {
        case .failed, .unsupported:
            return fallback
        case .idle, .searching, .noMatches, .matches:
            return displayedResults.isEmpty ? .noMatches : .matches
        }
    }

    private func emit(status: FileSearchSnapshot.Status) {
        let query = request?.query ?? ""
        onSnapshotChanged?(FileSearchSnapshot(
            query: query,
            results: displayedResults,
            status: status,
            isSearching: isSearchRunning,
            hasMore: computeHasMore(),
            totalMatchCount: results.count,
            isTruncated: didHitHardCap
        ))
    }

    private func computeHasMore() -> Bool {
        if displayedResults.count >= hardMaxResults { return false }
        if results.count > displayedResults.count { return true }
        return process?.isRunning == true
    }

    private func stopAndAdvanceGeneration() {
        isSearchRunning = false
        generation += 1
        // Any coalesced update from the prior generation is stale once
        // generation bumps; the drain Task already guards on generation but
        // dropping the slot here avoids a redundant drain hop.
        pendingPipelineUpdate = nil
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

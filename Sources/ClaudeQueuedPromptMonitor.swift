import CmuxAgentChat
import CmuxFoundation
import Foundation

/// Follows the transcript of the Claude Code session active in one terminal
/// pane and reports how many prompts are waiting in its input queue.
///
/// Runs only while Claude is working in a pane with prompt editing enabled.
/// The first read folds a bounded tail of the file; later reads fold only
/// appended bytes.
actor ClaudeQueuedPromptMonitor {
    /// Bytes read from the end of the transcript on start. Queued prompts
    /// live seconds to minutes, so their operations are near the end.
    static let initialTailBytes: UInt64 = 512 * 1024

    /// How often, and how many times, to look for the pane's transcript when
    /// the hook store hasn't recorded it yet.
    static let pathRetryInterval: Duration = .seconds(1)
    static let pathRetryLimit = 10

    private let surfaceID: UUID
    private let hookStoreURL: URL
    private var isStopped = false
    private let onChange: @MainActor @Sendable (Int) -> Void
    private var ledger = ClaudeQueuedPromptLedger()
    private var offset: UInt64 = 0
    private var fragment = Data()
    private var watcher: FileWatcher?
    private var watchTask: Task<Void, Never>?

    private var path = ""

    init(
        surfaceID: UUID,
        hookStoreURL: URL = RestorableAgentKind.claude.hookStoreFileURL(),
        onChange: @escaping @MainActor @Sendable (Int) -> Void
    ) {
        self.surfaceID = surfaceID
        self.hookStoreURL = hookStoreURL
        self.onChange = onChange
    }

    deinit {
        // Ends the watch loop, which releases the watcher and its file sources.
        watchTask?.cancel()
    }

    func start() async {
        guard watcher == nil else { return }
        // The prompt-submit hook records the transcript just before the turn
        // starts, so a missing path is usually a moment early.
        var path = Self.activeTranscriptPath(surfaceID: surfaceID, hookStoreURL: hookStoreURL)
        var attempts = 0
        while path == nil, attempts < Self.pathRetryLimit, !isStopped {
            attempts += 1
            try? await Task.sleep(for: Self.pathRetryInterval)
            path = Self.activeTranscriptPath(surfaceID: surfaceID, hookStoreURL: hookStoreURL)
        }
        guard let path, !isStopped, watcher == nil else { return }
        self.path = path
        let watcher = FileWatcher(path: path, throttle: .milliseconds(150))
        self.watcher = watcher
        await drain(initial: true)
        watchTask = Task { [weak self] in
            for await _ in watcher.events {
                guard let self else { return }
                await self.drain(initial: false)
            }
        }
    }

    func stop() async {
        isStopped = true
        watchTask?.cancel()
        watchTask = nil
        await watcher?.stop()
        watcher = nil
    }

    /// Transcript of the session the Claude hook store marks active on the surface.
    static func activeTranscriptPath(surfaceID: UUID, hookStoreURL: URL) -> String? {
        AgentPaneSessionLocator(agent: .claude, hookStoreURL: hookStoreURL)
            .session(surfaceID: surfaceID)?
            .transcriptPath
    }

    private func drain(initial: Bool) async {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return }
        var skipFirstLine = false
        let rebuilt = initial || end < offset
        if rebuilt {
            // First read, or the file was truncated or replaced: rebuild from the tail.
            ledger = ClaudeQueuedPromptLedger()
            fragment.removeAll()
            offset = end > Self.initialTailBytes ? end - Self.initialTailBytes : 0
            skipFirstLine = offset > 0
        }
        guard end > offset else { return }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: Int(end - offset)) else { return }
        offset = end
        var buffer = fragment + data
        if skipFirstLine {
            // The tail starts mid-line; drop the partial first line.
            guard let newline = buffer.firstIndex(of: 0x0A) else {
                fragment = buffer
                return
            }
            buffer = buffer[buffer.index(after: newline)...]
        }
        let before = ledger.count
        var lineStart = buffer.startIndex
        while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
            ledger.apply(line: Data(buffer[lineStart..<newline]))
            lineStart = buffer.index(after: newline)
        }
        fragment = Data(buffer[lineStart...])
        let count = ledger.count
        if rebuilt || count != before {
            await onChange(count)
        }
    }
}

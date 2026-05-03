import Foundation

/// Tails the active agent session's JSONL transcript and emits absolute file
/// paths extracted from each line. The "active session" file is selected by an
/// `AgentTranscriptSource`; the default `ClaudeCodeTranscriptSource` mirrors
/// the previous Claude Code-only behavior (project dir under
/// `~/.claude/projects/<sanitized cwd>/`, picking the most recently modified
/// `.jsonl`).
///
/// Used by `TurnCheckpointRegistry` to detect which git repo the agent is
/// currently operating on, since the workspace's static cwd may not match the
/// actual work directory (e.g. user starts the workspace at `~` but Claude does
/// work in `~/Desktop/projects/foo`).
///
/// Resolution: walks the source's `transcriptDirectory(forAnchorPwd:)` for the
/// most recently modified `.jsonl` and treats that as the active session.
/// Re-resolves periodically (every 30s) so a `/resume`-induced session swap is
/// picked up. While waiting for the directory or file to appear, polls every 2s
/// and tolerates either being missing.
///
/// All I/O happens on a background DispatchQueue. The `onPathDetected` callback
/// is invoked on the main queue so callers can safely mutate UI/main-actor state.
final class ClaudeTranscriptTailer {

    // MARK: - Public API

    private let workspaceCwd: String
    /// The pluggable agent transcript source used to resolve the transcript dir
    /// and to parse each JSONL line for file paths.
    private let source: AgentTranscriptSource
    private let onPathDetected: (String) -> Void
    /// Latest known focused-pane pwd and active claude session-id. Both are
    /// pushed in from the main actor and read on the tailer's background
    /// queue. Guarded by `anchorLock`. Pull-based MainActor.assumeIsolated
    /// from a background queue would crash with a libdispatch precondition.
    ///
    /// `latestClaudeSessionId` is authoritative: when non-nil, the tailer
    /// resolves to exactly `<sessionId>.jsonl` and never falls back. That's
    /// the only way to guarantee we don't tail an unrelated Claude Code
    /// instance that happens to share the anchor pwd.
    private var latestFocusedPanePwd: String?
    private var latestClaudeSessionId: String?
    private let anchorLock = NSLock()

    init(
        workspaceCwd: String,
        source: AgentTranscriptSource = ClaudeCodeTranscriptSource(),
        onPathDetected: @escaping (String) -> Void
    ) {
        self.workspaceCwd = workspaceCwd
        self.source = source
        self.onPathDetected = onPathDetected
    }

    /// Push a new focused-pane pwd snapshot into the tailer. Cheap; safe to call
    /// frequently from any thread.
    func updateFocusedPanePwd(_ pwd: String?) {
        anchorLock.lock()
        latestFocusedPanePwd = pwd
        anchorLock.unlock()
    }

    /// Push the active Claude Code `session_id` into the tailer. When set,
    /// resolves to `<dir>/<sessionId>.jsonl` exactly. When `nil`, the tailer
    /// idles — no fallback to mtime, which used to leak in transcripts from
    /// other Claude Code instances. Triggers an immediate re-resolve so a
    /// fresh session-id flips the tailer onto the new file without waiting
    /// for the 30s resolve tick.
    func updateClaudeSessionId(_ sid: String?) {
        anchorLock.lock()
        let changed = latestClaudeSessionId != sid
        latestClaudeSessionId = sid
        anchorLock.unlock()
        guard changed else { return }
        queue.async { [weak self] in
            self?.tickResolve()
        }
    }

    func start() {
        queue.async { [weak self] in
            self?.tickResolve()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.teardownLocked()
            self?.stopped = true
        }
    }

    // MARK: - Internal state

    private let queue = DispatchQueue(label: "com.cmux.ClaudeTranscriptTailer", qos: .utility)
    private var stopped = false

    private var currentTranscriptPath: String?
    private var currentFD: Int32 = -1
    private var currentOffset: off_t = 0
    private var dispatchSource: DispatchSourceFileSystemObject?

    /// Periodic timer that re-resolves the latest `.jsonl` (handles /resume).
    private var resolveTimer: DispatchSourceTimer?
    /// Polling timer used while the project dir / .jsonl doesn't exist yet.
    private var waitTimer: DispatchSourceTimer?

    private static let resolveIntervalSeconds: Int = 30
    private static let waitIntervalSeconds: Int = 2

    // MARK: - Resolution

    /// Best-effort resolve: prefer the most-recent focused pane pwd snapshot,
    /// then fall back to the workspace cwd.
    private func anchorPath() -> String {
        anchorLock.lock()
        let snap = latestFocusedPanePwd
        anchorLock.unlock()
        if let p = snap, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return p
        }
        return workspaceCwd
    }

    // MARK: - Tick / lifecycle

    /// Called on `queue`. Looks up the latest transcript and either
    ///   - opens it (or switches to it if it changed),
    ///   - or schedules a wait poll if the dir/file isn't there yet.
    ///
    /// The transcript source is queried with the workspace's claude launch
    /// timestamp so we ignore jsonl files belonging to OTHER Claude Code
    /// instances that happen to share the anchor pwd.
    private func tickResolve() {
        if stopped { return }

        let anchor = anchorPath()
        guard let dirURL = source.transcriptDirectory(forAnchorPwd: anchor) else {
            scheduleWaitTimer()
            return
        }
        let dir = dirURL.path
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            scheduleWaitTimer()
            return
        }
        anchorLock.lock()
        let sid = latestClaudeSessionId
        anchorLock.unlock()
        guard let latestURL = source.resolveActiveTranscriptFile(in: dirURL, sessionId: sid) else {
            // No matching file. If we already had a transcript open (typical
            // after a session-id swap), tear it down so we don't keep tailing
            // an unrelated file from the previous resolve.
            if currentTranscriptPath != nil {
                teardownLocked()
            }
            scheduleWaitTimer()
            return
        }
        let latest = latestURL.path

        if latest != currentTranscriptPath {
            switchTo(transcript: latest)
        }
        // Always (re)arm the long-period resolve timer.
        scheduleResolveTimer()
    }

    /// Tears down the active fd/dispatch source and opens `path` at end-of-file.
    /// Called on `queue`.
    private func switchTo(transcript path: String) {
        teardownLocked()
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        if fd < 0 { return }
        let endOffset = lseek(fd, 0, SEEK_END)
        if endOffset < 0 {
            close(fd)
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let mask = src.data
            if mask.contains(.delete) || mask.contains(.rename) {
                // File rotated out from under us — trigger an immediate re-resolve.
                self.teardownLocked()
                self.tickResolve()
                return
            }
            self.drainNewlyAppended()
        }
        src.setCancelHandler {
            close(fd)
        }
        src.resume()

        currentFD = fd
        currentOffset = endOffset
        dispatchSource = src
        currentTranscriptPath = path
    }

    /// Called on `queue`. Cancels source / timers / closes fd. Idempotent.
    private func teardownLocked() {
        if let src = dispatchSource {
            src.cancel()
            dispatchSource = nil
        }
        // close() is handled by the cancel handler above.
        currentFD = -1
        currentOffset = 0
        currentTranscriptPath = nil
    }

    private func scheduleResolveTimer() {
        resolveTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(
            deadline: .now() + .seconds(Self.resolveIntervalSeconds),
            repeating: .seconds(Self.resolveIntervalSeconds)
        )
        t.setEventHandler { [weak self] in self?.tickResolve() }
        t.resume()
        resolveTimer = t
    }

    private func scheduleWaitTimer() {
        waitTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(
            deadline: .now() + .seconds(Self.waitIntervalSeconds),
            repeating: .seconds(Self.waitIntervalSeconds)
        )
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // If we now have a file, this call will both attach and arm the long
            // resolve timer; the wait timer is then redundant.
            self.tickResolve()
            if self.currentTranscriptPath != nil {
                self.waitTimer?.cancel()
                self.waitTimer = nil
            }
        }
        t.resume()
        waitTimer = t
    }

    // MARK: - Read / parse

    private var partialLineBuffer = Data()

    private func drainNewlyAppended() {
        let fd = currentFD
        if fd < 0 { return }
        // Read chunks from currentOffset until EOF (current size).
        let endOffset = lseek(fd, 0, SEEK_END)
        if endOffset < 0 || endOffset <= currentOffset {
            // nothing to read (or seek failed; bail)
            return
        }
        _ = lseek(fd, currentOffset, SEEK_SET)

        let chunkSize = 64 * 1024
        var buf = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> ssize_t in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if n <= 0 { break }
            partialLineBuffer.append(buf, count: n)
            currentOffset += off_t(n)
            consumeLines()
            if n < chunkSize { break }
        }
    }

    private func consumeLines() {
        let newline: UInt8 = 0x0A
        while let idx = partialLineBuffer.firstIndex(of: newline) {
            let lineData = partialLineBuffer.subdata(in: 0..<idx)
            partialLineBuffer.removeSubrange(0...idx)
            if lineData.isEmpty { continue }
            handleLine(lineData)
        }
    }

    /// Hand the raw line off to the agent source for parsing, then emit each
    /// extracted absolute path on the main queue.
    private func handleLine(_ data: Data) {
        let anchor = anchorPath()
        let paths = source.extractPaths(fromLine: data, anchorPwd: anchor)
        guard !paths.isEmpty else { return }
        let cb = onPathDetected
        DispatchQueue.main.async {
            for p in paths { cb(p) }
        }
    }
}

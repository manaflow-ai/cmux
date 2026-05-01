import Foundation

/// Tails the active Claude Code session's JSONL transcript and emits absolute file
/// paths extracted from `tool_use` entries (Edit/Write/MultiEdit/Read/NotebookEdit
/// `file_path`, plus `cd <path>` arguments inside Bash `command`s).
///
/// Used by `TurnCheckpointRegistry` to detect which git repo the agent is currently
/// operating on, since the workspace's static cwd may not match the actual work
/// directory (e.g. user starts the workspace at `~` but Claude does work in
/// `~/Desktop/projects/foo`).
///
/// Resolution: walks `~/.claude/projects/<sanitized cwd>/` for the most recently
/// modified `.jsonl` and treats that as the active session. Re-resolves periodically
/// (every 30s) so a `/resume`-induced session swap is picked up. While waiting for
/// the directory or file to appear, polls every 2s and tolerates either being
/// missing (the user may not have used Claude Code yet).
///
/// All I/O happens on a background DispatchQueue. The `onPathDetected` callback is
/// invoked on the main queue so callers can safely mutate UI/main-actor state.
final class ClaudeTranscriptTailer {

    // MARK: - Public API

    private let workspaceCwd: String
    private let onPathDetected: (String) -> Void

    /// Latest known focused-pane pwd. Updated via `updateFocusedPanePwd(_:)`
    /// from the main actor; read on the tailer's background queue. Guarded by
    /// `anchorLock`. May be nil if no pane has been focused yet.
    private var latestFocusedPanePwd: String?
    private let anchorLock = NSLock()

    init(
        workspaceCwd: String,
        onPathDetected: @escaping (String) -> Void
    ) {
        self.workspaceCwd = workspaceCwd
        self.onPathDetected = onPathDetected
    }

    /// Push a new focused-pane pwd snapshot into the tailer. Cheap; safe to call
    /// frequently from any thread.
    func updateFocusedPanePwd(_ pwd: String?) {
        anchorLock.lock()
        latestFocusedPanePwd = pwd
        anchorLock.unlock()
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

    /// Project dir under `~/.claude/projects/` for the given cwd. Mirrors
    /// `SessionIndexStore.encodeClaudeProjectDir` ("/" -> "-").
    private static func projectDir(for cwd: String) -> String {
        let claudeRoot = ("~/.claude/projects" as NSString).expandingTildeInPath
        let encoded = cwd.replacingOccurrences(of: "/", with: "-")
        return (claudeRoot as NSString).appendingPathComponent(encoded)
    }

    /// Find the newest `.jsonl` directly inside `dir`, by mtime.
    private static func newestJSONL(in dir: String) -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        var best: (path: String, mtime: TimeInterval)?
        for entry in entries where entry.hasSuffix(".jsonl") {
            let full = (dir as NSString).appendingPathComponent(entry)
            guard let attrs = try? fm.attributesOfItem(atPath: full),
                  let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else {
                continue
            }
            if best == nil || mtime > best!.mtime {
                best = (full, mtime)
            }
        }
        return best?.path
    }

    // MARK: - Tick / lifecycle

    /// Called on `queue`. Looks up the latest transcript and either
    ///   - opens it (or switches to it if it changed),
    ///   - or schedules a wait poll if the dir/file isn't there yet.
    private func tickResolve() {
        if stopped { return }

        let dir = Self.projectDir(for: anchorPath())
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            scheduleWaitTimer()
            return
        }
        guard let latest = Self.newestJSONL(in: dir) else {
            scheduleWaitTimer()
            return
        }

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

    private func handleLine(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return }

        // Tool-use entries live nested inside `message.content[]` for assistant
        // messages. Walk both the legacy top-level shape and the nested shape.
        if let type = dict["type"] as? String, type == "tool_use" {
            extractAndEmit(fromToolUse: dict)
        }
        if let message = dict["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            for entry in content {
                if (entry["type"] as? String) == "tool_use" {
                    extractAndEmit(fromToolUse: entry)
                }
            }
        }
    }

    /// Pull `file_path` (Edit/Write/MultiEdit/Read/NotebookEdit) and `command`-cd
    /// targets (Bash) out of a tool_use object, resolve to absolute paths, and emit.
    private func extractAndEmit(fromToolUse tu: [String: Any]) {
        let name = (tu["name"] as? String) ?? ""
        guard let input = tu["input"] as? [String: Any] else { return }
        let anchor = anchorPath()

        switch name {
        case "Write", "Edit", "MultiEdit", "Read", "NotebookEdit":
            if let path = input["file_path"] as? String {
                emit(rawPath: path, anchor: anchor)
            }
            // MultiEdit's edits[] may not carry file_path; the top-level one is
            // what we need here. No additional walk required.

        case "Bash":
            if let cmd = input["command"] as? String {
                for cdPath in extractCdTargets(from: cmd) {
                    emit(rawPath: cdPath, anchor: anchor)
                }
                // Best-effort: also pick obvious absolute paths in the command.
                for abs in extractAbsolutePaths(from: cmd) {
                    emit(rawPath: abs, anchor: anchor)
                }
            }

        default:
            break
        }
    }

    /// Find `cd <path>` arguments. Tolerates `&&`, `;`, and quoted paths.
    private func extractCdTargets(from cmd: String) -> [String] {
        // Split on common shell separators, then look for tokens starting with `cd `.
        let separators = CharacterSet(charactersIn: ";&|")
        var results: [String] = []
        for piece in cmd.unicodeScalars
            .split(whereSeparator: { separators.contains($0) })
            .map({ String(String.UnicodeScalarView($0)) })
        {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("cd ") || trimmed == "cd" else { continue }
            let rest = trimmed.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
            if rest.isEmpty { continue }
            // Take the first whitespace-delimited token.
            let token = rest.split(separator: " ", maxSplits: 1).first.map(String.init) ?? rest
            // Strip surrounding quotes if any.
            var unquoted = token
            for quote in ["\"", "'"] {
                if unquoted.hasPrefix(quote) && unquoted.hasSuffix(quote) && unquoted.count >= 2 {
                    unquoted = String(unquoted.dropFirst().dropLast())
                }
            }
            results.append(unquoted)
        }
        return results
    }

    /// Best-effort scan for absolute paths in a command string. Returns at most a
    /// few candidates; caller is responsible for git-root resolution.
    private func extractAbsolutePaths(from cmd: String) -> [String] {
        var out: [String] = []
        var current: [Character] = []
        for ch in cmd {
            if ch == " " || ch == "\t" || ch == "\n" || ch == "\"" || ch == "'" {
                if !current.isEmpty {
                    let s = String(current)
                    if s.hasPrefix("/") { out.append(s) }
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            let s = String(current)
            if s.hasPrefix("/") { out.append(s) }
        }
        return out
    }

    /// Resolve `rawPath` to an absolute path (relative paths are joined onto
    /// `anchor`) and forward to the callback on the main queue.
    private func emit(rawPath: String, anchor: String) {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Expand ~ and ~/...
        let expanded = (trimmed as NSString).expandingTildeInPath

        let absolute: String
        if expanded.hasPrefix("/") {
            absolute = expanded
        } else {
            absolute = (anchor as NSString).appendingPathComponent(expanded)
        }

        let cb = onPathDetected
        DispatchQueue.main.async {
            cb(absolute)
        }
    }
}

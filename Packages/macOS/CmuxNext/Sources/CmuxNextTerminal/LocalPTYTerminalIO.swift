public import Foundation
import Darwin
import os
import CmuxNextCompat
public import CmuxNextTrace

/// A local shell on a PTY, exposed as a ``TerminalIO``. For development,
/// demos, and tests only: production terminals come from the cmux-tui
/// daemon. Nothing answers terminal queries on this side, so the surface runs
/// in `GHOSTTY_SURFACE_IO_MANUAL` and Ghostty replies to DA/DSR itself.
public nonisolated final class LocalPTYTerminalIO: TerminalIO {
    public enum SpawnError: Error, Sendable {
        case forkFailed(errno: Int32)
    }

    public let events: AsyncStream<TerminalIOEvent>
    public var answersTerminalQueries: Bool { false }

    /// The shell's process ID.
    public let processID: pid_t

    private let masterFD: Int32
    private let continuation: AsyncStream<TerminalIOEvent>.Continuation
    private let readQueue: DispatchQueue
    private let readSource: any DispatchSourceRead
    /// The output `events` holds that the session has not taken (``outputConsumed(_:)``): the read
    /// source pauses at its limit.
    private let outputWindow: ByteCreditWindow
    private let exitSource: any DispatchSourceProcess
    // qos-allow: key echo path: a typed key reaches the shell through this queue and its frame waits for the echo
    private let writeQueue = DispatchQueue(label: "com.cmuxterm.next.localpty.write", qos: .userInteractive)
    private let writeSource: any DispatchSourceWrite
    private let input: PendingInput
    private let closed = Atomic<Bool>(false)
    /// Watches each read chunk on the read queue (`localpty.read`), never the wait for readiness; nil watches nothing.
    private let readWatched: HangWatchedLane?

    /// One read chunk's budget (one `read(2)` of at most ``readChunkCapacity`` and its yield; a jank past it,
    /// a hang dump 2 s later): the descriptor is nonblocking, so a chunk that takes this long means the read
    /// queue is stuck.
    static let readHangDeadline: Duration = .seconds(1)
    /// One flush's budget (write until EAGAIN): the descriptor is nonblocking, so the same holds for writes.
    static let writeHangDeadline: Duration = .seconds(2)
    /// The output `events` may hold before the PTY is read no more: 1 MiB, as for pending input
    /// (``PendingInput``). A shell that prints faster than the surface parses then blocks in write(2),
    /// as it does under any terminal whose reader is slower.
    public static let outputBound = 1 << 20

    /// Spawns `shell` as a login shell in `workingDirectory`. `installedTerminfo` is the caller's lane read of
    /// ``GhosttyLaunchProbe/terminfoInstalled``: true makes the shell's `TERM`
    /// `xterm-ghostty`, false `xterm-256color` (``terminalEnvironment(resourcesDirectory:version:installedTerminfo:)``),
    /// unless `environment` sets it. The init reads no file for it. `hangs` watches each read chunk
    /// (`localpty.read`) and each input flush (`localpty.write`); nil watches nothing. `outputBound`: the
    /// output `events` may hold that the session has not taken before the PTY is read no more.
    public init(
        shell: String = LocalPTYTerminalIO.defaultShell,
        workingDirectory: String = NSHomeDirectory(),
        environment extra: [String: String] = [:],
        installedTerminfo: Bool,
        columns: Int = 80,
        rows: Int = 24,
        hangs: (any HangWatchScoping)? = nil,
        outputBound: Int = LocalPTYTerminalIO.outputBound
    ) throws {
        var environment = ProcessInfo.processInfo.environment
        for key in ["CMUX_SOCKET_PATH", "CMUX_SOCKET_ENABLE", "CMUX_TAG", "CMUX_BUNDLE_ID"] {
            environment.removeValue(forKey: key)
        }
        environment.merge(Self.terminalEnvironment(installedTerminfo: installedTerminfo)) { _, new in new }
        environment.merge(extra) { _, new in new }

        // Everything the child touches is allocated before fork: after fork
        // only async-signal-safe calls are allowed.
        let shellName = (shell as NSString).lastPathComponent
        let argv = CStringArray(["-" + shellName])
        let envp = CStringArray(environment.map { "\($0.key)=\($0.value)" })
        // SAFETY: two C copies this initializer owns, freed once (defer) after fork and execve
        // have read them in the child, which has its own copy of the memory.
        let path = unsafe strdup(shell)
        // SAFETY: as above.
        let directory = unsafe strdup(workingDirectory)
        defer {
            // SAFETY: as above.
            unsafe free(path)
            // SAFETY: as above.
            unsafe free(directory)
        }

        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        // The highest descriptor the child closes: the table size, read before fork, capped so an unlimited
        // limit does not make the child loop for long.
        let highestDescriptor = min(getdtablesize(), 1 << 16)
        var master: Int32 = -1
        // SAFETY: forkpty writes one descriptor into `master` and reads `size`, both alive for the
        // call; nil name and termios are allowed.
        let pid = unsafe forkpty(&master, nil, nil, &size)
        if pid == 0 {
            // The shell gets only its PTY (0-2): every app descriptor without close-on-exec (a socket, a
            // pipe, one received between recvmsg and FD_CLOEXEC) would pass through execve. close is
            // async-signal-safe.
            var descriptor: Int32 = 3
            while descriptor < highestDescriptor {
                _ = close(descriptor)
                descriptor += 1
            }
            // SAFETY: `directory` is the NUL-terminated copy made before fork (or nil, which
            // chdir rejects), still allocated in the child.
            _ = unsafe chdir(directory)
            // The app catches SIGPIPE (exec resets that), but a host process
            // that ignores it would pass SIG_IGN on: give the shell the default.
            _ = signal(SIGPIPE, SIG_DFL)
            // SAFETY: `path` and both NULL-terminated arrays were allocated before fork and are
            // alive in the child (CStringArray); execve only reads them.
            unsafe execve(path, argv.pointer, envp.pointer)
            _exit(127)
        }
        guard pid > 0 else { throw SpawnError.forkFailed(errno: errno) }

        // After the last throw: an init that throws registers nothing (its deinit does not run).
        let readWatched = hangs.map { HangWatchedLane("localpty.read", deadline: Self.readHangDeadline, on: $0) }
        self.readWatched = readWatched
        input = PendingInput(watched: hangs.map { HangWatchedLane("localpty.write", deadline: Self.writeHangDeadline, on: $0) })
        processID = pid
        masterFD = master
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

        // concurrency-allow: debug-only local PTY (CMUX_NEXT_DEBUG_TERMINAL), not the daemon path
        // memory: bounded-by outputWindow (outputBound, 1 MiB, plus one read chunk): the read source pauses at it
        let (stream, continuation) = AsyncStream<TerminalIOEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream
        self.continuation = continuation
        let outputWindow = ByteCreditWindow(limit: outputBound)
        self.outputWindow = outputWindow

        let readQueue = DispatchQueue(label: "com.cmuxterm.next.localpty.read", qos: .userInteractive)
        self.readQueue = readQueue
        readSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: readQueue)
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: master, queue: writeQueue)
        exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: readQueue)

        readSource.setEventHandler { [continuation, master, readSource, readWatched, outputWindow] in
            switch Self.drain(master, into: continuation, watched: readWatched, window: outputWindow) {
            case .drained: break
            // The session holds `outputBound` bytes: read again once it took them (outputConsumed).
            // Suspended here, on the read queue, where every resume runs too, so the two pair.
            case .full: readSource.suspend()
            // The slave side closed while the shell may live on: stop
            // reading, or the level-triggered source fires forever on the
            // hung-up master. The exit source still ends the stream.
            case .hangup: readSource.cancel()
            }
        }
        // The stream ended (finish) or its consumer went: a paused source resumes, so that it can be
        // cancelled and released, and a shell no one reads any more never blocks on a full PTY.
        continuation.onTermination = { [readQueue, readSource, outputWindow] _ in
            readQueue.async { if outputWindow.releasePause() { readSource.resume() } }
        }
        exitSource.setEventHandler { [weak self] in
            self?.finish()
        }
        readSource.resume()
        exitSource.resume()
        writeSource.setEventHandler { [input, writeSource, master] in input.flush(to: master, source: writeSource) }
        writeSource.setCancelHandler { [master] in close(master) }
    }

    /// The write queue's QoS (tests).
    var writeQueueQoS: DispatchQoS { writeQueue.qos }
    /// Output `events` holds that the session has not taken (tests).
    var bufferedOutputBytes: Int { outputWindow.bufferedBytes }
    /// True while the PTY is not read because the session holds `outputBound` bytes (tests).
    var isOutputPaused: Bool { outputWindow.isPaused }

    /// The session took `bytes` of output: the read source resumes, on the read queue, once the session
    /// holds half the bound or less.
    public func outputConsumed(_ bytes: Int) {
        guard outputWindow.consumed(bytes) else { return }
        readQueue.async { [readSource, outputWindow] in
            if outputWindow.resumeIfDrained() { readSource.resume() }
        }
    }

    deinit {
        terminate()
        finish()
        readWatched?.unregister()
    }

    /// Queues `data` for the PTY. Writes are nonblocking: when the PTY is
    /// full a write source resumes them, so a shell that stops reading never
    /// parks a thread. Input beyond `PendingInput.limit` is dropped.
    public func write(_ data: Data) async {
        guard !closed.load(ordering: .acquiring) else { return }
        writeQueue.async { [input, writeSource, masterFD] in
            input.append(data)
            input.flush(to: masterFD, source: writeSource)
        }
    }

    /// The session's input drains on the write queue (``TerminalInputLane``): a key's bytes reach the
    /// PTY's pending input in one hop from the thread that typed it.
    public func inputDrain() -> TerminalInputDrain {
        TerminalInputDrain(queue: writeQueue) { [self] record, _ in
            switch record {
            case .bytes(let data):
                guard !closed.load(ordering: .acquiring) else { break }
                input.append(data)
                input.flush(to: masterFD, source: writeSource)
            case .resize(let grid, let width, let height):
                setSize(cols: grid.columns, rows: grid.rows, pixelWidth: width, pixelHeight: height)
            case .focusGained, .takeOverSize, .reconnect, .resync:
                break
            }
            return .next
        }
    }

    public func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {
        setSize(cols: cols, rows: rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    private func setSize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        guard !closed.load(ordering: .acquiring) else { return }
        var size = winsize(
            ws_row: UInt16(clamping: rows),
            ws_col: UInt16(clamping: cols),
            ws_xpixel: UInt16(clamping: pixelWidth),
            ws_ypixel: UInt16(clamping: pixelHeight)
        )
        // SAFETY: TIOCSWINSZ reads one winsize, which `size` is, alive for the call.
        _ = unsafe ioctl(masterFD, TIOCSWINSZ, &size)
    }

    /// Sends SIGHUP to the shell, as closing a terminal window does.
    public func terminate() {
        guard !closed.load(ordering: .acquiring) else { return }
        kill(processID, SIGHUP)
    }

    private func finish() {
        guard closed.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else { return }
        exitSource.cancel()
        readSource.cancel()

        // Output written just before exit may still be buffered: at most the PTY's own buffer, read past
        // the window. The stream's end (onTermination) resumes a paused read source.
        Self.drain(masterFD, into: continuation, watched: readWatched, window: outputWindow, pauses: false)
        var status: Int32 = 0
        // SAFETY: waitpid writes one Int32 into `status`, alive for the call.
        _ = unsafe waitpid(processID, &status, WNOHANG)
        // The write source's cancel handler closes the descriptor once GCD
        // is done with it.
        writeQueue.async { [input, writeSource] in input.cancel(writeSource) }
        continuation.yield(.exited)
        continuation.finish()
    }

    public static var defaultShell: String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return shell }
        // SAFETY: getpwuid's entry and its NUL-terminated pw_shell stay valid until the next
        // getpw* call; String(cString:) copies the shell at once.
        if let entry = unsafe blockingGetpwuid(getuid()), let shell = unsafe entry.pointee.pw_shell {
            // SAFETY: as above.
            let path = unsafe String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }

    /// Ghostty's terminal identity, as the daemon's terminals get it
    /// (`TerminalEnvironment.instance.ghostty` in CmuxNextDaemon): `xterm-256color`
    /// unless `installedTerminfo` (the caller's lane read of
    /// ``GhosttyLaunchProbe/terminfoInstalled``) says `xterm-ghostty` is
    /// installed in a system terminfo directory; `COLORTERM`, `TERM_PROGRAM=ghostty`
    /// and its version. `TERMINFO` is not set. It reads no file, so a shell can be
    /// spawned from the main thread (p02-threads-006).
    static func terminalEnvironment(
        resourcesDirectory: String? = GhosttyRuntime.resourcesDirectory(),
        version: String? = GhosttyRuntime.version,
        installedTerminfo: Bool = false
    ) -> [String: String] {
        var result = ["COLORTERM": "truecolor", "TERM_PROGRAM": "ghostty", "TERM": "xterm-256color"]
        if let version, !version.isEmpty { result["TERM_PROGRAM_VERSION"] = version }
        if let resourcesDirectory, !resourcesDirectory.isEmpty { result["GHOSTTY_RESOURCES_DIR"] = resourcesDirectory }
        if installedTerminfo { result["TERM"] = "xterm-ghostty" }
        return result
    }
}

/// Input waiting for a PTY that is not reading.
private nonisolated final class PendingInput: Sendable {
    static let limit = 1 << 20
    // Lock carve-out: taken only on the PTY's serial write queue (append, flush and cancel all run there), so it
    // is never contended; it makes that confinement a checked Sendable instead of an unchecked promise.
    private let state = Mutex(State())
    /// Watches each flush on the write queue (`localpty.write`), never input waiting its turn; nil watches nothing.
    private let watched: HangWatchedLane?

    init(watched: HangWatchedLane?) {
        self.watched = watched
    }

    deinit {
        watched?.unregister()
    }

    func append(_ bytes: Data) {
        state.withLock { $0.append(bytes) }
    }

    /// Writes the pending bytes until the PTY is full (EAGAIN), inside one scope when there is a watcher.
    func flush(to fd: Int32, source: any DispatchSourceWrite) {
        guard let watched else { return state.withLock { $0.flush(to: fd, source: source) } }
        watched.run { state.withLock { $0.flush(to: fd, source: source) } }
    }

    func cancel(_ source: any DispatchSourceWrite) {
        state.withLock { $0.cancel(source) }
    }

    /// The bytes not written yet and the write source's state.
    private nonisolated struct State {
        var data = Data()
        var offset = 0
        var armed = false
        var cancelled = false

        mutating func append(_ bytes: Data) {
            guard !cancelled, data.count - offset + bytes.count <= PendingInput.limit else { return }
            data.append(bytes)
        }

        mutating func flush(to fd: Int32, source: any DispatchSourceWrite) {
            while !cancelled, offset < data.count {
                // SAFETY: offset < data.count (the loop's condition), so base + offset and the
                // raw.count - offset bytes after it lie inside the buffer, alive for the closure.
                let written = unsafe data.withUnsafeBytes { [offset] raw -> Int in
                    // SAFETY: offset < data.count, so the buffer has a base address; without one, drop the data.
                    guard let base = unsafe raw.baseAddress else { return 0 }
                    // concurrency-allow: nonblocking PTY descriptor, on the private write queue.
                    // SAFETY: as above.
                    return unsafe Darwin.write(fd, base + offset, raw.count - offset)
                }
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else if written < 0, errno == EAGAIN {
                    if !armed {
                        armed = true
                        source.resume()
                    }
                    return
                } else {
                    break
                }
            }
            data.removeAll(keepingCapacity: data.count <= 64 * 1024)
            offset = 0
            if armed, !cancelled {
                armed = false
                source.suspend()
            }
        }

        mutating func cancel(_ source: any DispatchSourceWrite) {
            guard !cancelled else { return }
            cancelled = true
            // A suspended source must be resumed before it can be cancelled.
            if !armed { source.resume() }
            armed = true
            source.cancel()
        }
    }
}

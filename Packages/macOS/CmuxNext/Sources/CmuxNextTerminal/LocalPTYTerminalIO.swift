public import Foundation
import Darwin
import os
import Synchronization

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
    private let readSource: any DispatchSourceRead
    private let exitSource: any DispatchSourceProcess
    private let writeQueue = DispatchQueue(label: "com.cmuxterm.next.localpty.write")
    private let closed = Atomic<Bool>(false)

    /// Spawns `shell` as a login shell in `workingDirectory`.
    public init(
        shell: String = LocalPTYTerminalIO.defaultShell,
        workingDirectory: String = NSHomeDirectory(),
        environment extra: [String: String] = [:],
        columns: Int = 80,
        rows: Int = 24
    ) throws {
        var environment = ProcessInfo.processInfo.environment
        for key in ["CMUX_SOCKET_PATH", "CMUX_SOCKET_ENABLE", "CMUX_TAG", "CMUX_BUNDLE_ID"] {
            environment.removeValue(forKey: key)
        }
        environment.merge(Self.terminalEnvironment()) { _, new in new }
        environment.merge(extra) { _, new in new }

        // Everything the child touches is allocated before fork: after fork
        // only async-signal-safe calls are allowed.
        let shellName = (shell as NSString).lastPathComponent
        let argv = CStringArray(["-" + shellName])
        let envp = CStringArray(environment.map { "\($0.key)=\($0.value)" })
        let path = strdup(shell)
        let directory = strdup(workingDirectory)
        defer {
            free(path)
            free(directory)
        }

        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &size)
        if pid == 0 {
            _ = chdir(directory)
            execve(path, argv.pointer, envp.pointer)
            _exit(127)
        }
        guard pid > 0 else { throw SpawnError.forkFailed(errno: errno) }

        processID = pid
        masterFD = master
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

        let (stream, continuation) = AsyncStream<TerminalIOEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream
        self.continuation = continuation

        let readQueue = DispatchQueue(label: "com.cmuxterm.next.localpty.read", qos: .userInteractive)
        readSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: readQueue)
        exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: readQueue)

        readSource.setEventHandler { [continuation, master] in
            Self.drain(master, into: continuation)
        }
        exitSource.setEventHandler { [weak self] in
            self?.finish()
        }
        readSource.resume()
        exitSource.resume()
    }

    deinit {
        terminate()
        finish()
    }

    public func write(_ data: Data) async {
        guard !closed.load(ordering: .acquiring) else { return }
        let fd = masterFD
        writeQueue.async {
            data.withUnsafeBytes { buffer in
                guard var base = buffer.baseAddress else { return }
                var remaining = buffer.count
                while remaining > 0 {
                    let written = Darwin.write(fd, base, remaining)
                    if written > 0 {
                        remaining -= written
                        base = base.advanced(by: written)
                    } else if written < 0, errno == EAGAIN || errno == EINTR {
                        // The PTY buffer is full; wait until it drains.
                        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&descriptor, 1, -1)
                    } else {
                        return
                    }
                }
            }
        }
    }

    public func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {
        guard !closed.load(ordering: .acquiring) else { return }
        var size = winsize(
            ws_row: UInt16(clamping: rows),
            ws_col: UInt16(clamping: cols),
            ws_xpixel: UInt16(clamping: pixelWidth),
            ws_ypixel: UInt16(clamping: pixelHeight)
        )
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
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
        // Output written just before exit may still be buffered.
        Self.drain(masterFD, into: continuation)
        var status: Int32 = 0
        _ = waitpid(processID, &status, WNOHANG)
        close(masterFD)
        continuation.yield(.exited)
        continuation.finish()
    }

    private static func drain(_ fd: Int32, into continuation: AsyncStream<TerminalIOEvent>.Continuation) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            // EAGAIN: drained. EIO or 0: the slave side closed.
            guard count > 0 else { return }
            continuation.yield(.output(Data(buffer[0..<count])))
        }
    }

    public static var defaultShell: String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return shell }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }

    /// TERM and friends. Uses `xterm-ghostty` when the terminfo entry is
    /// reachable next to the Ghostty resources, else `xterm-256color`.
    private static func terminalEnvironment() -> [String: String] {
        var result = ["COLORTERM": "truecolor", "TERM_PROGRAM": "cmux", "TERM": "xterm-256color"]
        if let resources = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] {
            let terminfo = ((resources as NSString).deletingLastPathComponent as NSString).appendingPathComponent("terminfo")
            if FileManager.default.fileExists(atPath: (terminfo as NSString).appendingPathComponent("78/xterm-ghostty")) {
                result["TERMINFO"] = terminfo
                result["TERM"] = "xterm-ghostty"
            }
        }
        return result
    }
}

/// NULL-terminated `char *[]` that outlives a fork.
private nonisolated final class CStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointer = .allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() {
            pointer[index] = strdup(string)
        }
        pointer[strings.count] = nil
    }

    deinit {
        for index in 0..<count { free(pointer[index]) }
        pointer.deallocate()
    }
}

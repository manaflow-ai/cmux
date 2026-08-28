import Darwin
import Foundation

/// Discovers attachable sessions by running one POSIX-sh probe script:
/// locally via `/bin/sh -s`, and on a user-added SSH destination via
/// `ssh <dest> sh -s` (one round-trip per host, script on stdin). Every
/// stanza tolerates a missing tool, so the probe never fails as a whole.
enum HarborSessionProbe {
    /// A remote tool can print arbitrary session metadata. Keep the process
    /// and parser bounded before that data reaches the model or the sidebar.
    static let maxOutputBytes = 1 * 1024 * 1024
    static let outputChunkBytes = 64 * 1024

    /// Emits one `tool<TAB>name<TAB>state<TAB>detail` line per session.
    /// Keep this POSIX-sh portable: it also runs on remote Linux hosts.
    static let script = #"""
    #!/bin/sh
    emit() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }

    if command -v tmux >/dev/null 2>&1; then
      tmux ls -F '#{session_name}	#{?session_attached,attached,detached}	#{session_windows}w' 2>/dev/null |
      while IFS='	' read -r n st d; do emit tmux "$n" "$st" "$d"; done
    fi

    if command -v zellij >/dev/null 2>&1; then
      zellij list-sessions --no-formatting 2>/dev/null |
      while read -r n rest; do
        case "$rest" in *EXITED*) st=exited;; *) st=detached;; esac
        [ -n "$n" ] && emit zellij "$n" "$st" ""
      done
    fi

    if command -v screen >/dev/null 2>&1; then
      screen -ls 2>/dev/null | sed -n 's/^[[:space:]]\{1,\}\([^[:space:]]*\)[[:space:]]*(\(.*\))/\1	\2/p' |
      while IFS='	' read -r n st; do
        case "$st" in *ttached*) s=attached;; *) s=detached;; esac
        emit screen "$n" "$s" ""
      done
    fi

    if command -v zmx >/dev/null 2>&1; then
      zmx list 2>/dev/null | while read -r line; do
        n=""; c=""
        for kv in $line; do
          case "$kv" in name=*) n=${kv#name=};; clients=*) c=${kv#clients=};; esac
        done
        [ -n "$n" ] || continue
        if [ "${c:-0}" -gt 0 ] 2>/dev/null; then s=attached; else s=detached; fi
        emit zmx "$n" "$s" ""
      done
    fi

    if command -v herdr >/dev/null 2>&1; then
      herdr session list 2>/dev/null | tail -n +2 |
      while read -r n st dir _; do
        [ -n "$n" ] && emit herdr "$n" "$st" "$dir"
      done
    fi

    CT=""
    if command -v cmux-tui >/dev/null 2>&1; then CT=cmux-tui
    elif [ -x "$HOME/.local/bin/cmux-tui" ]; then CT="$HOME/.local/bin/cmux-tui"; fi
    if [ -n "$CT" ]; then
      for d in "${TMPDIR:-/tmp}/cmux-tui-$(id -u)" "/tmp/cmux-tui-$(id -u)"; do
        [ -d "$d" ] || continue
        for s in "$d"/*.sock; do
          [ -S "$s" ] || continue
          n=$(basename "$s" .sock)
          if "$CT" --socket "$s" server status 2>/dev/null | grep -q "is running"; then
            emit cmux-tui "$n" running "$s"
          fi
        done
      done
    fi
    exit 0
    """#

    enum ProbeError: Error, Equatable {
        case launchFailed
        case timedOut
        case outputTooLarge
        case failed(exitCode: Int32)
    }

    /// Runs the probe for one source off the main actor and parses the result.
    /// Discovery uses `BatchMode=yes`, so an SSH host that needs interactive
    /// auth reports as unreachable here; the attach path intentionally uses
    /// plain `ssh -t`, so its prompts render inside the terminal pane.
    static func discoverSessions(
        source: HarborSource,
        ownSessionName: String?,
        timeout: TimeInterval = 8
    ) async throws -> [HarborSession] {
        let (executable, arguments): (String, [String])
        switch source {
        case .local:
            (executable, arguments) = ("/bin/sh", ["-s"])
        case .ssh(let destination):
            (executable, arguments) = ("/usr/bin/ssh", [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=6",
                "--", destination,
                "sh -s",
            ])
        }
        let output = try await runScript(executable: executable, arguments: arguments, timeout: timeout)
        return HarborProbeOutputParser.sessions(
            fromProbeOutput: output,
            source: source,
            ownSessionName: ownSessionName
        )
    }

    private static func runScript(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> String {
        let cancellation = HarborProbeProcessCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try runScriptBlocking(
                            executable: executable,
                            arguments: arguments,
                            timeout: timeout,
                            cancellation: cancellation
                        )
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func runScriptBlocking(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        cancellation: HarborProbeProcessCancellation
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let stdoutHandle = stdout.fileHandleForReading
        let stderrHandle = stderr.fileHandleForReading
        cancellation.register(process: process, handles: [stdoutHandle, stderrHandle])
        defer { cancellation.clear() }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            cancellation.clear()
            throw ProbeError.launchFailed
        }
        if cancellation.isCancelled {
            cancellation.cancel()
            process.waitUntilExit()
            throw CancellationError()
        }
        stdin.fileHandleForWriting.write(Data(script.utf8))
        try? stdin.fileHandleForWriting.close()

        // Drain both pipes off-thread so a chatty probe cannot deadlock on a
        // full pipe buffer before the termination handler fires.
        let outputBox = HarborProbeOutputBox()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let (data, overflowed) = readBounded(stdoutHandle, maximumBytes: Self.maxOutputBytes)
            outputBox.storeStdout(data, overflowed: overflowed)
            drained.signal()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let overflowed = drainBounded(stderrHandle, maximumBytes: Self.maxOutputBytes)
            outputBox.storeStderrOverflow(overflowed)
            drained.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            cancellation.cancel()
            process.waitUntilExit()
            _ = drained.wait(timeout: .now() + 2)
            _ = drained.wait(timeout: .now() + 2)
            throw ProbeError.timedOut
        }
        process.waitUntilExit()
        let stdoutDrained = drained.wait(timeout: .now() + 2) == .success
        let stderrDrained = drained.wait(timeout: .now() + 2) == .success
        guard stdoutDrained, stderrDrained else {
            // A child that keeps a pipe open after its parent exits is not a
            // complete probe result. Close the handles and fail closed.
            cancellation.cancel()
            throw ProbeError.timedOut
        }
        if cancellation.isCancelled {
            throw CancellationError()
        }
        if outputBox.outputOverflowed() {
            throw ProbeError.outputTooLarge
        }
        guard process.terminationStatus == 0 else {
            throw ProbeError.failed(exitCode: process.terminationStatus)
        }
        return String(data: outputBox.takeStdout(), encoding: .utf8) ?? ""
    }
}

/// Cancels and reaps a probe process when a refresh is replaced or cancelled.
/// The process and pipe handles are registered under one lock so cancellation
/// cannot miss a launch that races the task handler.
private final class HarborProbeProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var handles: [FileHandle] = []
    private var cancelled = false

    func register(process: Process, handles: [FileHandle]) {
        lock.lock()
        self.process = process
        self.handles = handles
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel {
            terminate(process: process, handles: handles)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        let handles = self.handles
        lock.unlock()
        guard let process else {
            close(handles)
            return
        }
        terminate(process: process, handles: handles)
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func clear() {
        lock.lock()
        process = nil
        handles.removeAll()
        lock.unlock()
    }

    private func terminate(process: Process, handles: [FileHandle]) {
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            if pid > 1 {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
        close(handles)
    }

    private func close(_ handles: [FileHandle]) {
        for handle in handles {
            try? handle.close()
        }
    }
}

/// Read at most `maximumBytes + 1` bytes. The extra byte distinguishes an
/// exact limit from an overflow without ever retaining the unbounded tail.
private func readBounded(_ handle: FileHandle, maximumBytes: Int) -> (Data, Bool) {
    var data = Data()
    data.reserveCapacity(min(maximumBytes, HarborSessionProbe.outputChunkBytes))
    var overflowed = false
    while data.count <= maximumBytes {
        let remaining = maximumBytes + 1 - data.count
        let chunk = handle.readData(ofLength: min(remaining, HarborSessionProbe.outputChunkBytes))
        if chunk.isEmpty { break }
        data.append(chunk)
    }
    if data.count > maximumBytes {
        overflowed = true
        data.removeLast(data.count - maximumBytes)
        // Closing the read end makes a chatty child receive SIGPIPE instead
        // of blocking forever after the cap is reached. The caller still
        // observes `outputTooLarge` after the process is reaped.
        try? handle.close()
    }
    return (data, overflowed)
}

/// Drain a diagnostic pipe without retaining remote bytes. The extra byte
/// distinguishes an exact limit from an overflow and then closes the read end
/// so a chatty child cannot remain blocked on a full pipe.
private func drainBounded(_ handle: FileHandle, maximumBytes: Int) -> Bool {
    var total = 0
    while total <= maximumBytes {
        let remaining = maximumBytes + 1 - total
        let chunk = handle.readData(ofLength: min(remaining, HarborSessionProbe.outputChunkBytes))
        if chunk.isEmpty { return false }
        total += chunk.count
        if total > maximumBytes {
            try? handle.close()
            return true
        }
    }
    return false
}

/// Lock-guarded buffers for the off-thread probe pipe drains.
private final class HarborProbeOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var overflowed = false

    func storeStdout(_ data: Data, overflowed: Bool) {
        lock.lock()
        stdout = data
        self.overflowed = self.overflowed || overflowed
        lock.unlock()
    }

    func storeStderrOverflow(_ overflowed: Bool) {
        lock.lock()
        self.overflowed = self.overflowed || overflowed
        lock.unlock()
    }

    func outputOverflowed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return overflowed
    }

    func takeStdout() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return stdout
    }
}

import Foundation

/// Discovers attachable sessions by running one POSIX-sh probe script:
/// locally via `/bin/sh -s`, and on a user-added SSH destination via
/// `ssh <dest> sh -s` (one round-trip per host, script on stdin). Every
/// stanza tolerates a missing tool, so the probe never fails as a whole.
enum HarborSessionProbe {
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
        case failed(exitCode: Int32, stderr: String)
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
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try runScriptBlocking(executable: executable, arguments: arguments, timeout: timeout)
                })
            }
        }
    }

    private static func runScriptBlocking(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
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
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw ProbeError.launchFailed
        }
        stdin.fileHandleForWriting.write(Data(script.utf8))
        try? stdin.fileHandleForWriting.close()

        // Drain both pipes off-thread so a chatty probe cannot deadlock on a
        // full pipe buffer before the termination handler fires.
        let outputBox = HarborProbeOutputBox()
        let drained = DispatchSemaphore(value: 0)
        let stdoutHandle = stdout.fileHandleForReading
        let stderrHandle = stderr.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            outputBox.storeStdout(stdoutHandle.readDataToEndOfFile())
            drained.signal()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            outputBox.storeStderr(stderrHandle.readDataToEndOfFile())
            drained.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            throw ProbeError.timedOut
        }
        _ = drained.wait(timeout: .now() + 2)
        _ = drained.wait(timeout: .now() + 2)
        guard process.terminationStatus == 0 else {
            throw ProbeError.failed(
                exitCode: process.terminationStatus,
                stderr: String(data: outputBox.takeStderr(), encoding: .utf8) ?? ""
            )
        }
        return String(data: outputBox.takeStdout(), encoding: .utf8) ?? ""
    }
}

/// Lock-guarded buffers for the off-thread probe pipe drains.
private final class HarborProbeOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func storeStdout(_ data: Data) {
        lock.lock()
        stdout = data
        lock.unlock()
    }

    func storeStderr(_ data: Data) {
        lock.lock()
        stderr = data
        lock.unlock()
    }

    func takeStdout() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return stdout
    }

    func takeStderr() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return stderr
    }
}

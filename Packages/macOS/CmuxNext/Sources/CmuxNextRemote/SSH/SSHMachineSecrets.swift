public import CmuxNextCloud
import CmuxNextCompat
import Darwin
public import Foundation

/// `cmux cloud deliver-secrets` to an own machine: an SSH machine, or an acpmux peer this Mac reaches
/// over ssh. The receiver and its protocol are a Cloud machine's (``CloudMachineSecrets``): the same
/// script, ticket, payload and answers, writing `~/.config/cmux/machine-secrets.env` (0600). Only the
/// carrier differs: the person's own ssh, with the app's options (``SSHCommandLine/enforcedOptions``).
///
/// - One `ssh … 'sh -s'` writes the receiver and its ticket (the nonce, the payload key and the names,
///   never a value) from its stdin into `~/.cmux/machine-config` (0700): never an argv or a log.
/// - One `ssh -tt … sh receiver ticket` runs the receiver on a pty of its own. Only this process reads
///   that pty and types into it: no daemon, no terminal another client watches. The payload goes to
///   ssh's stdin once the receiver says echo is off, and the run ends on every path.
///
/// The values never cross a daemon link: the person's delivery writes them to the machine, and its
/// shells and agents read them from the file.
public struct SSHMachineSecrets {
    public init() {}
    /// The machine's folder for the receiver and its ticket, as a remote shell expands it.
    public static let directory = "$HOME/.cmux/machine-config"
    public static let receiverPath = directory + "/receive-secrets"
    /// One delivery's ticket, named by its `word` (hex): deliveries to one machine under two names (an
    /// SSH machine and a peer alias) never read each other's.
    public static func ticketPath(_ word: String) -> String { directory + "/receive-secrets.\(word).ticket" }
    /// Where the receiver writes the values (``CloudMachineSecrets/receiver``).
    public static let envFile = "~/.config/cmux/machine-secrets.env"
    /// The line a shell profile on the machine needs for its shells and agents to see the values: an own
    /// machine has no machine config that sources the file, and cmux never edits a person's profile.
    public static let sourceLine = #"[ -f "$HOME/.config/cmux/machine-secrets.env" ] && . "$HOME/.config/cmux/machine-secrets.env""#

    /// The ssh destination of an acpmux peer's URL (`ssh://[user@]host[:port]`, the port being the
    /// peer daemon's, never ssh's); nil for any other transport or a URL ssh could misread.
    public static func destination(peerURL: String) -> SSHDestination? {
        guard peerURL.lowercased().hasPrefix("ssh://"), let parsed = try? SSHDestination(parsing: peerURL) else { return nil }
        let host = parsed.host.contains(":") ? "[\(parsed.host)]" : parsed.host
        return try? SSHDestination(parsing: parsed.user.map { "\($0)@\(host)" } ?? host)
    }

    /// The script `sh -s` runs on the machine: the receiver and the ticket, each from a quoted here-document
    /// whose end word occurs in neither, into a 0700 folder with umask 077. The receiver is replaced by a
    /// rename, so a delivery already running keeps reading the copy it opened; tickets a delivery never
    /// used (its receiver did not start) go after 10 minutes.
    static func installScript(ticket: Data, word: String) -> String {
        let receiver = "CMUX_RECEIVER_\(word)", ticketEnd = "CMUX_TICKET_\(word)"
        let body = String(decoding: ticket, as: UTF8.self)
        let text = body.hasSuffix("\n") ? body : body + "\n"
        return """
            set -eu
            umask 077
            d="\(directory)"
            mkdir -p "$d"
            chmod 700 "$d"
            find "$d" -name 'receive-secrets.*.ticket' -mmin +10 -exec rm -f {} + 2>/dev/null || true
            cat > "$d/.receive-secrets.\(word)" <<'\(receiver)'
            \(CloudMachineSecrets.receiver)
            \(receiver)
            mv -f "$d/.receive-secrets.\(word)" "$d/receive-secrets"
            cat > "$d/receive-secrets.\(word).ticket" <<'\(ticketEnd)'
            \(text)\(ticketEnd)

            """
    }

    /// Why a delivery over ssh stopped before the receiver answered: ssh's own last line (no value ever
    /// reaches ssh's output: the payload is typed only after echo is off, and only into the pty).
    public struct Unreachable: Error, Equatable, Sendable {
        public var message: String
    }

    /// The delivery's calls over ssh to `destination` (see ``CloudMachineSecrets/deliver(_:over:nonce:key:receiverAt:ticketAt:)``,
    /// with ``receiverPath`` and ``ticketPath(_:)`` of the same `word`, a fresh hex word per delivery).
    public static func link(to destination: SSHDestination, environment: [String: String],
                            commandLine: SSHCommandLine = SSHCommandLine(), word: String) -> CloudMachineSecrets.Link {
        let run = PTYBox()
        return CloudMachineSecrets.Link(
            writeTicket: { ticket in
                let result = try await SSHProcessRunner.run(commandLine.script(destination), input: .data(Data(installScript(ticket: ticket, word: word).utf8)),
                                                            environment: environment, deadline: .seconds(60), label: "secrets receiver install")
                guard result.status == 0 else { throw Unreachable(message: lastLine(result.stderr)) }
            },
            start: { argv in
                guard let command = remoteCommand(argv) else { throw CloudMachineSecrets.DeliveryFailed(reason: "unexpected") }
                let pty = try SSHPTYRun(commandLine.pty(destination, command), environment: environment)
                run.set(pty)
                return "pty"
            },
            waitFor: { _, pattern, seconds in
                guard let pty = run.get() else { throw CloudMachineSecrets.DeliveryFailed(reason: "unexpected") }
                return try await pty.waitFor(pattern, seconds: seconds)
            },
            type: { _, bytes in
                guard let pty = run.get() else { throw CloudMachineSecrets.DeliveryFailed(reason: "unexpected") }
                try await pty.type(bytes)
            },
            close: { _ in await run.get()?.stop() })
    }

    /// `argv` as one remote command line: the first word plain, the rest in double quotes, so the
    /// login shell (sh, bash, zsh, fish) expands `$HOME` and nothing else. Only the fixed paths above pass.
    static func remoteCommand(_ argv: [String]) -> String? {
        let plain = argv.allSatisfy { word in
            !word.isEmpty && word.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "$/._-".unicodeScalars.contains($0)) }
        }
        guard plain, let first = argv.first else { return nil }
        return ([first] + argv.dropFirst().map { "\"\($0)\"" }).joined(separator: " ")
    }

    static func lastLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "ssh failed"
    }

    /// The one pty run of a delivery, set by `start`.
    private final class PTYBox: Sendable {
        private let value = Mutex<SSHPTYRun?>(nil)
        func set(_ run: SSHPTYRun) { value.withLock { $0 = run } }
        func get() -> SSHPTYRun? { value.withLock { $0 } }
    }
}

/// One `ssh -tt` run: its output collected as it arrives (the last 64 KiB), bytes typed into its stdin,
/// and a stop that ends it. Read by raw descriptor (never `availableData`, which can raise).
final class SSHPTYRun: Sendable {
    /// The process and the parent's pipe ends: not Sendable, so reached only under the lock.
    private struct Running {
        var process: Process
        var stdin: Pipe
        var stdout: Pipe
        var stopped = false
    }

    private let output: OutputBuffer
    private let running: Mutex<Running>
    private let input: Int32
    private let changes: AsyncStream<Void>
    /// Whether ssh has exited (its termination handler), for ``stop()`` to wait on.
    private let exit: ExitSignal

    init(_ argv: [String], environment: [String: String]) throws {
        guard let executable = argv.first else { throw CocoaError(.executableNotLoadable) }
        let process = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // ssh's own messages (a host key, an auth failure) are not the receiver's answer: dropped.
        process.standardError = FileHandle.nullDevice
        let (changes, changed) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.changes = changes
        let exit = ExitSignal()
        self.exit = exit
        process.terminationHandler = { _ in exit.fire() }
        input = stdinPipe.fileHandleForWriting.fileDescriptor
        // A write after ssh ended fails with EPIPE instead of signalling the app.
        _ = fcntl(input, F_SETNOSIGPIPE, 1)
        // Writes never block: a stalled ssh (a full channel, a receiver gone after READY) ends the
        // write at its deadline instead of holding the delivery forever (``type(_:seconds:)``).
        _ = fcntl(input, F_SETFL, fcntl(input, F_GETFL) | O_NONBLOCK)
        let output = OutputBuffer(), fd = stdoutPipe.fileHandleForReading.fileDescriptor
        self.output = output
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR || errno == EAGAIN { return }
            // End of file or a read error: the waits end.
            guard count > 0 else {
                handle.readabilityHandler = nil
                changed.finish()
                return
            }
            output.append(buffer[..<count])
            changed.yield()
        }
        running = Mutex(Running(process: process, stdin: stdinPipe, stdout: stdoutPipe))
        try running.withLock { try $0.process.run() }
    }

    /// The output so far once it matches `pattern`; throws when the run ends first or `seconds` pass.
    @concurrent func waitFor(_ pattern: String, seconds: Int) async throws -> String {
        _ = try Regex(pattern)
        let output = output
        let match: @Sendable () -> String? = {
            guard let regex = try? Regex(pattern) else { return nil }
            let text = output.text
            return text.contains(regex) ? text : nil
        }
        let changes = changes
        return try await withDeadline(.seconds(seconds), label: "secrets receiver") {
            if let text = match() { return text }
            for await _ in changes {
                if let text = match() { return text }
            }
            if let text = match() { return text }
            throw CloudMachineSecrets.DeliveryFailed(reason: "eof")
        }
    }

    /// Writes `bytes` to ssh's stdin, all of them, off the caller's thread, within `seconds` in all
    /// (one deadline, however the bytes trickle out). Throws when ssh ended, the run was stopped, the
    /// task was cancelled, or the deadline passed; the caller's close then stops ssh.
    @concurrent func type(_ bytes: Data, seconds: Int = 60) async throws {
        let fd = input, deadline = ContinuousClock.now + .seconds(seconds)
        let wroteAll: Bool = bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                guard !Task.isCancelled, !self.running.withLock({ $0.stopped }) else { return false }
                let wrote = Darwin.write(fd, base + offset, raw.count - offset)
                if wrote > 0 { offset += wrote; continue }
                guard wrote < 0, errno == EINTR || errno == EAGAIN else { return false }
                if errno == EINTR { continue }
                // Full: wait for room in slices of at most a second, so a stop or a cancel is seen soon.
                let left = deadline - ContinuousClock.now
                guard left > .zero else { return false }
                let slice = Int32(min(1000, max(1, left.components.seconds * 1000 + left.components.attoseconds / 1_000_000_000_000_000)))
                var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let polled = poll(&ready, 1, slice)
                if polled < 0, errno != EINTR { return false }
                if polled > 0, ready.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return false }
            }
            return true
        }
        guard wroteAll else { throw CloudMachineSecrets.DeliveryFailed(reason: "eof") }
    }

    /// Whether ssh is still running (tests).
    var isRunning: Bool { !exit.done }

    /// Ends the run, once: its stdin closes and ssh stops, which hangs up the receiver's pty. Returns
    /// when ssh has exited, whether or not the caller was cancelled.
    func stop() async {
        let first = running.withLock { running -> (process: Process, stdout: FileHandle)? in
            guard !running.stopped else { return nil }
            running.stopped = true
            try? running.stdin.fileHandleForWriting.close()
            if running.process.isRunning { running.process.terminate() }
            return (running.process, running.stdout.fileHandleForReading)
        }
        guard let first else { return }
        let pid = first.process.processIdentifier
        // Its own task, so a cancelled delivery still ends ssh: no stopped run leaves an ssh, its pipes or
        // the machine's pty behind. An ssh still running 3 s after the hang-up is killed.
        // task-owner: the stop's own cleanup; it ends when ssh has exited, which SIGKILL guarantees
        let cleanup = Task { [exit] in
            // task-owner: the kill deadline; cancelled as soon as ssh exits
            let killer = Task { [exit] in
                // wakeup-allow: a one-shot escalation deadline for an ssh that ignores SIGTERM, cancelled once it exits
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled, !exit.done { kill(pid, SIGKILL) }
            }
            await exit.ended()
            killer.cancel()
        }
        await cleanup.value
        first.stdout.readabilityHandler = nil
        try? first.stdout.close()
    }

}

/// The moment ssh exited, once; waiters before or after it all return.
private final class ExitSignal: Sendable {
    private struct State {
        var done = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var done: Bool { state.withLock { $0.done } }

    func fire() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.done = true
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func ended() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let done = state.withLock { state -> Bool in
                if !state.done { state.waiters.append(waiter) }
                return state.done
            }
            if done { waiter.resume() }
        }
    }
}

/// What a run printed so far, the last 64 KiB: enough for every answer line, bounded whatever ssh prints.
private final class OutputBuffer: Sendable {
    private let bytes = Mutex(Data())

    func append(_ chunk: ArraySlice<UInt8>) {
        bytes.withLock { bytes in
            bytes.append(contentsOf: chunk)
            if bytes.count > 64 * 1024 { bytes.removeFirst(bytes.count - 64 * 1024) }
        }
    }

    var text: String { bytes.withLock { String(decoding: $0, as: UTF8.self) } }
}

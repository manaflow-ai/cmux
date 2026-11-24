import CmuxNextCompat
import CmuxNextComputerUse
import CmuxScreenKit
import CoreGraphics
import Foundation
import os

/// The iPhone viewer's WebRTC screen host in its own process (``MacScreenStreamChild``): the app's
/// executable in `--screen-stream-host` mode, started by the Screen Sharing helper
/// (`cmux-screen-sharing __webrtc-host`) as the helper's child, so its capture and input use the
/// helper's grants and a grant never relaunches this app (plans/cmux-next/screen-sharing-helper.md).
/// This side relays the session's signaling to it in ``MacScreenStreamLine`` JSON lines: the viewer's
/// signals in, the host's signals, ICE requests, events and end out. The viewer's protocol is the
/// session's own, unchanged.
nonisolated final class MacScreenStreamProcess: Sendable {
    /// A child that ended without a `done` line, or one whose session failed.
    struct Failed: LocalizedError {
        var reason: String
        var errorDescription: String? { reason }
    }

    private let lines: AsyncStream<MacScreenStreamLine>
    private let continuation: AsyncStream<MacScreenStreamLine>.Continuation
    private let state = Mutex(State())
    // Signals and stop: a session's setup waits for them, no frame does.
    private let writes = DispatchQueue(label: "com.cmuxterm.mac-screen.stream-stdin", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mac-screen-stream")

    private struct State {
        var stdin: FileHandle?
        /// Kept for this object's life: a released `Pipe` closes its read end under its
        /// readabilityHandler (cmuxterm-hq#13721, as ``MacScreenRdProcess``).
        var pipes: [Pipe] = []
        var stderrTail = Data()
        var stopped = false
    }

    init() {
        (lines, continuation) = AsyncStream.makeStream(of: MacScreenStreamLine.self, bufferingPolicy: .bufferingOldest(1024))
    }

    /// The helper's arguments that start this app's executable as the stream host.
    static func helperArguments(appExecutable: URL) -> [String] {
        ["__webrtc-host", appExecutable.path, MacScreenStreamChild.flag]
    }

    /// Starts the child through the staged Screen Sharing helper. Off the caller's actor: staging
    /// the helper's copy reads and may copy files.
    @concurrent func startInHelper(_ helper: MacScreenHelper) async throws {
        guard let executable = await helper.executable() else { throw MacScreenHelper.NotStaged(helper: helper.name) }
        guard let app = Bundle.main.executableURL else { throw Failed(reason: "this app has no executable path") }
        let arguments = Self.helperArguments(appExecutable: app)
        let pid = try start { stdin, stdout, stderr in
            try MacScreenHelper.spawn(executable, arguments, stdin: stdin, stdout: stdout, stderr: stderr)
        }
        logger.info("serving a WebRTC viewer from the Screen Sharing helper (pid \(pid, privacy: .public))")
    }

    /// Starts a process `spawn` launches on these pipes (the helper; tests pass a shell) and reads
    /// its lines. The pipes stay with this object.
    @discardableResult
    func start(_ spawn: (_ stdin: Pipe, _ stdout: Pipe, _ stderr: Pipe) throws -> pid_t) throws -> pid_t {
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        follow(stdout: stdout, stderr: stderr)
        let pid: pid_t
        do { pid = try spawn(stdin, stdout, stderr) } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            throw error
        }
        SignedHelperLaunch.reap(pid)
        let stopped = state.withLock { state in
            state.stdin = stdin.fileHandleForWriting
            state.pipes = [stdin, stdout, stderr]
            return state.stopped
        }
        // Stopped before it started: it ends at once.
        if stopped { stop() }
        return pid
    }

    private func follow(stdout: Pipe, stderr: Pipe) {
        let continuation = continuation
        let splitter = Mutex(MacScreenStreamLineSplitter())
        stdout.fileHandleForReading.readabilityHandler = { handle in
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            let data = handle.blockingAvailableData()
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            for line in splitter.withLock({ $0.push(data) }) { continuation.yield(line) }
        }
        let logger = logger
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            let data = handle.blockingAvailableData()
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8) { logger.info("\(text, privacy: .public)") }
            self?.state.withLock { state in
                state.stderrTail.append(data)
                if state.stderrTail.count > 4096 { state.stderrTail.removeFirst(state.stderrTail.count - 4096) }
            }
        }
    }

    /// Writes one line to the child (dropped once it ended).
    func send(_ line: MacScreenStreamLine) {
        guard let data = line.encoded, let handle = state.withLock({ $0.stdin }) else { return }
        writes.async { try? handle.write(contentsOf: data) }
    }

    /// The windows the child's capture leaves out, the whole list (SECURITY).
    func exclude(_ ids: Set<CGWindowID>) {
        send(MacScreenStreamLine(excludeWindows: ids.sorted()))
    }

    var stderrTail: String { state.withLock { String(data: $0.stderrTail, encoding: .utf8) ?? "" } }

    /// Ends the session: `stop`, then the child's input closes (it ends on end of file).
    func stop() {
        send(MacScreenStreamLine(stop: true))
        let handle = state.withLock { state -> FileHandle? in
            state.stopped = true
            defer { state.stdin = nil }
            return state.stdin
        }
        writes.async { try? handle?.close() }
    }

    /// Serves one session in the started child: sends the setup with the windows its capture leaves
    /// out, relays `signaling` both ways, and returns when the child's session ends (it throws when
    /// that session failed, or the child ended without saying).
    /// `afterSetup` runs once the setup is queued, so every line it sends (the exclusion watch's) reaches the
    /// child after the setup's own list, never before it.
    func serve(_ signaling: any ScreenSignaling, name: String, viewOnly: Bool, excluded: Set<CGWindowID>,
               afterSetup: () -> Void = {},
               events: @escaping @Sendable (MacScreenStreamLine.Event, String?) -> Void) async throws {
        // SECURITY: the list is on the setup's own line, applied before the capture starts.
        send(MacScreenStreamLine(setup: .init(name: name, viewOnly: viewOnly, endsSessionOnClose: signaling.endsSessionOnClose),
                                 excludeWindows: excluded.sorted()))
        afterSetup()
        // task-owner: the viewer's signals to the child; cancelled when the child's session ends
        let inbound = Task { [weak self] in
            do {
                for try await signal in signaling.messages() { self?.send(MacScreenStreamLine(signal: .init(signal))) }
            } catch {}
            // The session's signaling ended: so does the child's session.
            self?.stop()
        }
        defer { inbound.cancel() }
        for await line in lines {
            if let signal = line.signal?.signal { try? await signaling.send(signal) }
            if let id = line.iceRequest {
                // task-owner: one ICE answer; it ends with the session's ICE fetch
                Task { [weak self] in
                    let ice: MacScreenStreamLine.ICE
                    do { ice = .init(id: id, servers: try await signaling.iceServers()) } catch {
                        ice = .init(id: id, error: String(describing: error))
                    }
                    self?.send(MacScreenStreamLine(ice: ice))
                }
            }
            if let ready = line.ready {
                logger.info("WebRTC host ready; the helper's grants: screen recording \(ready.screenRecording, privacy: .public), accessibility \(ready.accessibility, privacy: .public)")
            }
            if let event = line.event { events(event, line.message) }
            if line.close == true { signaling.close() }
            if let done = line.done {
                if let error = done.error { throw Failed(reason: error) }
                return
            }
        }
        let tail = stderrTail
        throw Failed(reason: tail.isEmpty ? "the screen stream host stopped" : tail)
    }
}

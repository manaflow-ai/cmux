import CmuxNextCompat
import CmuxNextComputerUse
import CmuxScreenKit
import CoreGraphics
import Foundation
import os

/// One WebRTC viewer's session (the iPhone's Screen Sharing viewer, or a Mac from before cmux.rd/1)
/// served by the Screen Sharing helper (``MacScreenHelper``), never in this app: the helper's
/// `__webrtc-host` (cmux-tui/crates/cmux-rd-host src/webrtc_host.rs) runs the WebRTC host
/// `cmux-screen-sharing-webrtc` from its own bundle as its child, so the ScreenCaptureKit capture
/// and the CGEvent input are checked against the helper's Screen Recording and Accessibility
/// grants. This app never asks for either and never relaunches for one.
///
/// This object keeps the session's signaling and relays it in JSON lines (CmuxVNCWebRTC
/// `ScreenRelayLine`) over the helper's stdin and stdout: the setup (name, scope, ICE servers and,
/// SECURITY, the app's windows the capture leaves out, before any capture can start), the viewer's
/// signals, the exclusion list again on every change, and `stop`. The helper's signals go to the
/// viewer, its events to ``onEvent``.
nonisolated final class MacScreenWebRTCRelay: Sendable {
    /// The helper's pipes, as ``Launch`` started it.
    struct Child: Sendable {
        /// The helper's stdin (this side writes).
        var input: FileHandle
        /// The helper's stdout (this side reads).
        var output: FileHandle
        /// The helper's stderr (diagnostics), if kept.
        var errors: FileHandle?
        /// Kept for the session: a released `Pipe` closes its read end under its reader, and the
        /// helper's lines then go nowhere (cmuxterm-hq#13721).
        var pipes: [Pipe] = []
    }

    /// Starts the helper (tests start a stand-in on pipes).
    typealias Launch = @Sendable () async throws -> Child

    private struct State {
        var child: Child?
        /// The session's signaling while ``serve(_:)`` runs (`bye` on disconnect, as `ScreenStreamHost`).
        var signaling: (any ScreenSignaling)?
        var stopped = false
        /// The viewer connected (a helper that ends afterwards ended a session, not its start).
        var connected = false
        /// An `ended` or `failed` event went: the helper's end of file says nothing more.
        var finished = false
        var exclusions: Task<Void, Never>?
        var reader: Task<Void, Never>?
        var stderrTail = Data()
        var stopReading: [@Sendable () -> Void] = []
    }

    let name: String
    let viewOnly: Bool
    private let launch: Launch
    private let readExcludedWindows: @Sendable () -> Set<CGWindowID>
    private let recheck: Duration
    private let state = Mutex(State())
    private let handler = Mutex<(@Sendable (MacScreenRdHost.Event) -> Void)?>(nil)
    // Lines in order; a full pipe never blocks the caller.
    private let writes = DispatchQueue(label: "com.cmuxterm.mac-screen.webrtc-relay-stdin", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mac-screen-webrtc-relay")

    init(name: String, viewOnly: Bool, launch: @escaping Launch = MacScreenWebRTCRelay.launchHelper,
         excludedWindows: @escaping @Sendable () -> Set<CGWindowID> = { CaptureExcludedWindows().windowIDs },
         recheck: Duration = CaptureExcludedWindows.recheck) {
        self.name = name
        self.viewOnly = viewOnly
        self.launch = launch
        readExcludedWindows = excludedWindows
        self.recheck = recheck
    }

    var onEvent: (@Sendable (MacScreenRdHost.Event) -> Void)? {
        get { handler.load() }
        set { handler.store(newValue) }
    }

    private func emit(_ event: MacScreenRdHost.Event) {
        handler.load()?(event)
    }

    /// This build bundles no Screen Sharing helper: the session fails with this (never a capture
    /// here), in the same plain words as ``MacScreenRdHost``'s other host failures.
    struct NoHelper: LocalizedError {
        var errorDescription: String? { "this build has no Screen Sharing helper to serve the viewer" }
    }

    /// The Screen Sharing helper's verified copy, `__webrtc-host`, responsibility disclaimed.
    @concurrent static func launchHelper() async throws -> Child {
        guard let helper = MacScreenHelper.bundled() else { throw NoHelper() }
        guard let executable = await helper.executable() else { throw MacScreenHelper.NotStaged(helper: helper.name) }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        let pid = try MacScreenHelper.spawn(executable, ["__webrtc-host"], stdin: stdin, stdout: stdout, stderr: stderr)
        SignedHelperLaunch.reap(pid)
        return Child(input: stdin.fileHandleForWriting, output: stdout.fileHandleForReading,
                     errors: stderr.fileHandleForReading, pipes: [stdin, stdout, stderr])
    }

    /// Serves the session until the helper's host has served its signaling (as `ScreenStreamHost.serve`
    /// returns): a connected session lives on in the helper until the viewer leaves or
    /// ``disconnectViewer()``. A helper that does not start fails the session (``onEvent``).
    func serve(_ signaling: any ScreenSignaling) async throws {
        let servers = try await signaling.iceServers()
        let child: Child
        do { child = try await launch() } catch {
            logger.error("the Screen Sharing helper did not start: \(String(describing: error), privacy: .public)")
            emit(.sourceFailed(error.localizedDescription))
            return
        }
        let (served, servedSink) = AsyncStream.makeStream(of: String?.self, bufferingPolicy: .bufferingNewest(1))
        let begun = state.withLock { state -> Bool in
            guard !state.stopped else { return false }
            state.child = child
            state.signaling = signaling
            return true
        }
        guard begun else {
            try? child.input.close()
            return
        }
        // A helper that exited before reading a line makes the write fail (EPIPE), never SIGPIPE the app.
        _ = fcntl(child.input.fileDescriptor, F_SETNOSIGPIPE, 1)
        defer { state.withLock { $0.signaling = nil } }
        follow(child, signaling: signaling, served: servedSink)
        // SECURITY: the first list goes with the setup, before the viewer's offer can start a capture.
        let excluded = readExcludedWindows()
        send(ScreenRelayLine(setup: ScreenRelaySetup(name: name, viewOnly: viewOnly,
                                                     endsSessionOnClose: signaling.endsSessionOnClose,
                                                     iceServers: servers, excludeWindows: excluded.sorted())))
        watchExclusions()
        logger.info("serving a WebRTC viewer from the Screen Sharing helper")
        do {
            for try await signal in signaling.messages() { send(ScreenRelayLine(signal: signal)) }
        } catch {
            send(ScreenRelayLine(signalsEnd: true))
            throw error
        }
        send(ScreenRelayLine(signalsEnd: true))
        for await result in served {
            if let result { throw Served(message: result) }
            return
        }
    }

    /// The helper's host threw from its serve (the viewer's offer did not verify, for one).
    struct Served: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Reads the helper's lines until its end of file: signals to the viewer, events to ``onEvent``,
    /// `served` to ``serve(_:)``.
    private func follow(_ child: Child, signaling: any ScreenSignaling, served: AsyncStream<String?>.Continuation) {
        let (chunks, stopChunks) = child.output.readyChunks()
        var stops = [stopChunks]
        if let errors = child.errors {
            let (lines, stopErrors) = errors.readyChunks()
            stops.append(stopErrors)
            let logger = logger
            // task-owner: the helper's stderr for this session; ends at its end of file or stop
            Task { [weak self] in
                for await data in lines {
                    logger.info("webrtc host: \(String(decoding: data, as: UTF8.self), privacy: .public)")
                    self?.state.withLock { state in
                        state.stderrTail.append(data)
                        if state.stderrTail.count > 4096 { state.stderrTail.removeFirst(state.stderrTail.count - 4096) }
                    }
                }
            }
        }
        // task-owner: the helper's stdout for this session; ends at its end of file, cancelled by disconnectViewer
        let reader = Task { [weak self] in
            var buffer = ScreenRelayLineBuffer()
            for await data in chunks {
                for line in buffer.push(data) {
                    guard let self else { return }
                    if let signal = line.signal?.signal { try? await signaling.send(signal) }
                    if line.close == true { signaling.close() }
                    if let event = line.event { handle(event: event, message: line.message) }
                    if line.served == true { served.yield(line.error) }
                }
            }
            served.finish()
            self?.helperEnded()
        }
        state.withLock { state in
            state.reader = reader
            state.stopReading = stops
        }
    }

    private func handle(event: String, message: String?) {
        switch event {
        case ScreenRelayLine.connected:
            state.withLock { $0.connected = true }
            emit(.viewerConnected)
        case ScreenRelayLine.ended:
            state.withLock { $0.finished = true }
            emit(.viewerEnded("the WebRTC viewer left"))
        case ScreenRelayLine.failed:
            state.withLock { $0.finished = true }
            emit(.sourceFailed(message ?? "the screen host stopped"))
        default:
            break
        }
    }

    /// The helper's stdout ended. Unless this side stopped it or it already said how the session
    /// ended, the helper stopped by itself (it crashed, or found no WebRTC host in its bundle).
    private func helperEnded() {
        let ended = state.withLock { state -> (connected: Bool, reason: String)? in
            state.exclusions?.cancel()
            guard !state.stopped, !state.finished else { return nil }
            state.finished = true
            let tail = String(decoding: state.stderrTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return (state.connected, tail.isEmpty ? "the screen host stopped" : tail)
        }
        guard let ended else { return }
        logger.error("the Screen Sharing helper's WebRTC host ended: \(ended.reason, privacy: .public)")
        emit(ended.connected ? .viewerEnded(ended.reason) : .sourceFailed(ended.reason))
    }

    /// SECURITY: the whole exclusion list again on every change while the session lasts.
    private func watchExclusions() {
        // The watch calls at once with the list it reads then: the helper drops a list it already has.
        let watch = MacScreenRdHost.watchExcludedWindows(read: readExcludedWindows, every: recheck) { [weak self] ids in
            self?.send(ScreenRelayLine(excludeWindows: ids.sorted()))
        }
        let keep = state.withLock { state -> Bool in
            guard !state.stopped, !state.finished else { return false }
            state.exclusions?.cancel()
            state.exclusions = watch
            return true
        }
        if !keep { watch.cancel() }
    }

    /// Writes one line to the helper (dropped once this side stopped it: its stdin is closed then).
    private func send(_ line: ScreenRelayLine) {
        guard let handle = state.withLock({ $0.stopped ? nil : $0.child?.input }) else { return }
        let data = line.encoded
        writes.async { try? handle.write(contentsOf: data) }
    }

    /// Stop: the helper ends the session (its peer connection closes) and exits; the viewer hears
    /// `bye` while the session's signaling is open, as from `ScreenStreamHost.disconnectViewer()`.
    func disconnectViewer() {
        let stopped = state.withLock { state -> (input: FileHandle?, signaling: (any ScreenSignaling)?, stops: [@Sendable () -> Void])? in
            guard !state.stopped else { return nil }
            state.stopped = true
            state.exclusions?.cancel()
            state.reader?.cancel()
            defer { state.stopReading = [] }
            return (state.child?.input, state.signaling, state.stopReading)
        }
        guard let stopped else { return }
        if let input = stopped.input {
            let line = ScreenRelayLine(stop: true).encoded
            writes.async {
                try? input.write(contentsOf: line)
                try? input.close()
            }
        }
        for stop in stopped.stops { stop() }
        if let signaling = stopped.signaling, signaling.endsSessionOnClose {
            // task-owner: the session's last word to the viewer; ends once sent
            Task {
                try? await signaling.send(.bye)
                signaling.close()
            }
        }
    }
}

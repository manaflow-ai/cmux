// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxDeviceHub
import CmuxRemoteWire
import CmuxVNCWebRTC
import Darwin
import Foundation
import os

private let logger = Logger(subsystem: "com.cmuxterm.remote", category: "attached-screen")

/// One Mac Screen session the cmux app serves through this worker (docs/cmux-remote.md,
/// Screen Sharing worker). The app keeps what it owns, the hub, the ticket, this Mac's consent,
/// approvals and the session's signaling; this worker captures and injects input, so macOS
/// checks the helper's Screen Recording and Accessibility, never cmux's, and a grant never
/// relaunches cmux. The app opens a Screen Sharing channel through the host, and its first
/// request picks the protocol the viewer offered:
///
/// - `session.rd`: this worker starts `cmux-screen-sharing serve`, the cmux.rd/1 host, as its own
///   child (same signed helper), and relays its JSON lines both ways unchanged: the app writes the
///   setup, candidates and `{"stop":true}`; the host's lines (key, candidates, connected, ended)
///   come back.
/// - `session.webrtc`: this worker runs `ScreenStreamHost`; its signals cross the channel as
///   `{"signal":{...}}` lines (``ScreenSignalWire``), `{"signals_done":true}` when the app's
///   signaling closed, and its state as `session` events (`connected`, `ended`, `failed`).
///
/// The channel ending without `{"stop":true}` is the app going away (it quit or crashed): a
/// connected session keeps serving when `remote.headless` is on (End Sharing When cmux Quits off),
/// and this worker owns it from then on (hub revocations, Stop Sharing from its menu bar item);
/// otherwise it stops.
final class AttachedScreenSession: Sendable {
    enum Kind: String, Sendable {
        case rd = "session.rd"
        case webRTC = "session.webrtc"
    }

    /// What the app says about the session when it opens the channel.
    struct Info: Sendable, Equatable {
        var id: String
        var viewerID: String
        var viewerName: String
        var scope: SessionScope
        /// The name a WebRTC viewer shows for this Mac.
        var name: String
        var servers: [ICEServerConfig]

        init?(_ params: [String: Any]) {
            guard let id = params["session_id"] as? String, !id.isEmpty,
                  let scope = (params["scope"] as? String).flatMap(SessionScope.init(rawValue:)) else { return nil }
            self.id = id
            viewerID = params["viewer_id"] as? String ?? ""
            viewerName = params["viewer_name"] as? String ?? ""
            self.scope = scope
            name = params["name"] as? String ?? (Host.current().localizedName ?? "Mac")
            servers = ScreenSignalWire.servers(params["ice_servers"])
        }
    }

    enum Event: Sendable, Equatable {
        /// The viewer's link is up.
        case connected
        /// The app went away while the session serves on (headless): this worker owns it now.
        case orphaned
        /// The session is over (the viewer left, the link failed, Stop).
        case ended(String)
    }

    let kind: Kind
    let info: Info
    let headless: Bool
    private let channel: LineChannel
    private let onEvent: @Sendable (Event, AttachedScreenSession) -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State: Sendable {
        var connected = false
        var ended = false
        /// The app asked for the stop (`{"stop":true}`), or this worker stopped it.
        var stopped = false
        var appGone = false
        /// cmux.rd/1: the host's stdin (``LineChannel`` write side), nil once closed.
        var stdin: LineChannel?
        /// WebRTC: the host and the app's incoming signals.
        var host: ScreenStreamHost?
        var signals: AsyncThrowingStream<ScreenSignal, any Error>.Continuation?
        /// Threads still using the channel's descriptor; the last one closes it.
        var channelUsers = 0
    }

    private init(kind: Kind, info: Info, headless: Bool, channel: LineChannel,
                 onEvent: @escaping @Sendable (Event, AttachedScreenSession) -> Void) {
        self.kind = kind
        self.info = info
        self.headless = headless
        self.channel = channel
        self.onEvent = onEvent
    }

    var connected: Bool { state.withLock { $0.connected } }

    /// Serves the app's channel whose first request is `request` (method `session.rd` or
    /// `session.webrtc`). Answers the request on the channel; nil (and the channel closed) when it
    /// was refused. `rdExecutable`: `cmux-screen-sharing` beside this worker. `onEvent` runs on the
    /// session's own threads.
    static func open(_ request: WorkerRequest, channel: LineChannel, headless: Bool, rdExecutable: String?,
                     environment: [String: String], logPath: String,
                     onEvent: @escaping @Sendable (Event, AttachedScreenSession) -> Void) -> AttachedScreenSession? {
        let id = request.id
        let refuse = { (code: String, message: String) -> AttachedScreenSession? in
            channel.write(RemoteWire.failure(id: id, code: code, message: message))
            channel.close()
            return nil
        }
        guard let kind = Kind(rawValue: request.method) else {
            return refuse("bad_request", "session.rd or session.webrtc is required")
        }
        guard let info = Info(request.params) else {
            return refuse("bad_request", "session_id and scope (view, full) are required")
        }
        let session = AttachedScreenSession(kind: kind, info: info, headless: headless, channel: channel, onEvent: onEvent)
        switch kind {
        case .rd:
            guard let rdExecutable, FileManager.default.isExecutableFile(atPath: rdExecutable) else {
                return refuse("rd_unavailable", "this helper carries no cmux.rd/1 host (cmux-screen-sharing)")
            }
            do { try session.startRd(executable: rdExecutable, environment: environment, logPath: logPath, id: id) } catch {
                return refuse("rd_failed", "the cmux.rd/1 host did not start: \(error)")
            }
        case .webRTC:
            session.startWebRTC(id: id)
        }
        logger.info("serving an attached \(kind.rawValue, privacy: .public) session for the app")
        return session
    }

    // MARK: cmux.rd/1

    private func startRd(executable: String, environment: [String: String], logPath: String, id: Any?) throws {
        let child = try ChildProcess.spawn(executable: executable, arguments: ["serve"], environment: environment, logPath: logPath)
        ChildProcess.watch(child.pid, name: "remote-screen-rd-reap") { status in
            logger.info("cmux.rd/1 host exited (\(status, privacy: .public))")
        }
        // The read side is unused: closeWrite closes the host's stdin once.
        let stdin = LineChannel(read: -1, write: child.stdin)
        state.withLock {
            $0.stdin = stdin
            $0.channelUsers = 2
        }
        channel.write(RemoteWire.answer(id: id, result: ["pid": Int(child.pid)]))
        // The host's lines to the app, unchanged; `connected` and `ended` are this worker's state too.
        let output = Thread { [self] in
            let lines = LineChannel(read: child.stdout, write: -1)
            while let line = lines.readLine() {
                if let object = RemoteWire.object(line) {
                    if object["connected"] as? Bool == true { markConnected() }
                    if let reason = object["ended"] as? String { finish(reason) }
                }
                var forwarded = line
                forwarded.append(0x0A)
                channel.write(forwarded)
            }
            Darwin.close(child.stdout)
            finish("the screen host stopped")
            // The app reads end of file: its rd process ends.
            _ = shutdown(channel.readDescriptor, SHUT_RDWR)
            releaseChannel()
        }
        output.name = "remote-screen-rd-out"
        output.start()
        // The app's lines to the host; `{"stop":true}` is the app's Stop.
        let input = Thread { [self] in
            while let line = channel.readLine() {
                let isStop = RemoteWire.object(line)?["stop"] as? Bool == true
                if isStop { state.withLock { $0.stopped = true } }
                var forwarded = line
                forwarded.append(0x0A)
                stdin.write(forwarded)
                if isStop {
                    stop()
                    break
                }
            }
            appLeft()
            releaseChannel()
        }
        input.name = "remote-screen-rd-in"
        input.start()
    }

    // MARK: WebRTC

    private func startWebRTC(id: Any?) {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ScreenSignal.self, throwing: (any Error).self,
                                                                    bufferingPolicy: .bufferingOldest(512))
        let channel = self.channel
        let signaling = ChannelSignaling(stream: stream, servers: info.servers) { signal in
            channel.write(RemoteWire.line(["signal": ScreenSignalWire.fields(signal)]))
        }
        let log: @Sendable (String) -> Void = { line in logger.info("\(line, privacy: .public)") }
        let host = ScreenStreamHost(name: info.name, viewOnly: info.scope == .view,
                                    backend: { ScreenCaptureBackend(log: log) }, log: log)
        host.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .viewerConnected:
                markConnected()
                channel.write(RemoteWire.event("session", ["kind": "connected"]))
            case .viewerEnded:
                channel.write(RemoteWire.event("session", ["kind": "ended", "reason": "the WebRTC viewer left"]))
                finish("the WebRTC viewer left")
            case let .sourceFailed(message):
                channel.write(RemoteWire.event("session", ["kind": "failed", "reason": message]))
                finish(message)
            case .waiting, .roomLost:
                break
            }
        }
        state.withLock {
            $0.host = host
            $0.signals = continuation
            $0.channelUsers = 1
        }
        channel.write(RemoteWire.answer(id: id, result: ["pid": Int(getpid())]))
        // task-owner: the WebRTC session; it ends with its signaling (a connected link outlives it) or stop()
        Task.detached { [weak self] in
            do { try await host.serve(signaling) } catch {
                logger.error("WebRTC host: \(String(describing: error), privacy: .public)")
            }
            guard let self, !connected else { return }
            channel.write(RemoteWire.event("session", ["kind": "ended", "reason": "the session's signaling closed"]))
            finish("the session's signaling closed")
        }
        let input = Thread { [self] in
            while let object = channel.readObject() {
                if object["stop"] as? Bool == true {
                    state.withLock { $0.stopped = true }
                    stop()
                    break
                }
                if let fields = object["signal"] as? [String: Any], let signal = ScreenSignalWire.signal(fields) {
                    continuation.yield(signal)
                }
                // The app's signaling closed (a connected link outlives it; the channel stays).
                if object["signals_done"] as? Bool == true { continuation.finish() }
            }
            continuation.finish()
            appLeft()
            releaseChannel()
        }
        input.name = "remote-screen-webrtc-in"
        input.start()
    }

    // MARK: State

    private func markConnected() {
        let first = state.withLock { state -> Bool in
            guard !state.connected, !state.ended else { return false }
            state.connected = true
            return true
        }
        if first { onEvent(.connected, self) }
    }

    /// The session ended (once).
    private func finish(_ reason: String) {
        let first = state.withLock { state -> Bool in
            guard !state.ended else { return false }
            state.ended = true
            return true
        }
        guard first else { return }
        stop()
        onEvent(.ended(reason), self)
    }

    /// The app's channel ended. Without its Stop, a connected session serves on when headless.
    private func appLeft() {
        let keep = state.withLock { state -> Bool? in
            guard !state.appGone else { return nil }
            state.appGone = true
            guard !state.stopped, !state.ended else { return nil }
            return headless && state.connected
        }
        guard let keep else { return }
        if keep {
            logger.notice("the app left; the connected session serves on (headless)")
            onEvent(.orphaned, self)
        } else {
            finish("the cmux app left")
        }
    }

    /// Ends the capture: the cmux.rd/1 host hears `stop` and end of file; the WebRTC host
    /// disconnects its viewer.
    func stop() {
        let (stdin, host, signals) = state.withLock { state in
            state.stopped = true
            defer {
                state.stdin = nil
                state.host = nil
                state.signals = nil
            }
            return (state.stdin, state.host, state.signals)
        }
        if let stdin {
            stdin.write(RemoteWire.line(["stop": true]))
            stdin.closeWrite()
        }
        signals?.finish()
        // Closing the peer connection waits on WebRTC's threads: never on the caller's.
        if let host { Task.detached { host.disconnectViewer() } }
    }

    /// One reader or writer thread is done with the channel; the last closes it.
    private func releaseChannel() {
        let last = state.withLock { state -> Bool in
            state.channelUsers -= 1
            return state.channelUsers == 0
        }
        guard last else { return }
        // Writes refuse from now on (a late event never reaches a reused descriptor), then it closes.
        channel.closeWrite()
        channel.close()
    }
}

/// The app's ticket signaling, as seen from this worker: its signals arrive on the channel and
/// this side's go back on it; the session's ICE servers came with the open request.
final class ChannelSignaling: ScreenSignaling {
    private let stream: AsyncThrowingStream<ScreenSignal, any Error>
    private let servers: [ICEServerConfig]
    private let write: @Sendable (ScreenSignal) -> Void

    init(stream: AsyncThrowingStream<ScreenSignal, any Error>, servers: [ICEServerConfig],
         write: @escaping @Sendable (ScreenSignal) -> Void) {
        self.stream = stream
        self.servers = servers
        self.write = write
    }

    func messages() -> AsyncThrowingStream<ScreenSignal, any Error> { stream }
    func send(_ signal: ScreenSignal) async throws { write(signal) }
    func iceServers() async throws -> [ICEServerConfig] { servers }
    func close() {}
    /// The app's signaling is the hub ticket's: it ends the session when it closes.
    var endsSessionOnClose: Bool { true }
}

// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxRemoteWire
import CmuxVNCWebRTC
import Darwin
import Foundation
import os

private let logger = Logger(subsystem: "com.cmuxterm.remote", category: "attached-screen")

/// The cmux app's attached Mac Screen sessions, served here so macOS checks cmux Remote's
/// Screen Recording and Accessibility, never the app's (docs/cmux-remote.md, "Attached
/// capture"; the wire is `AttachedScreenHost` in CmuxVNCWebRTC). The app keeps the hub ticket,
/// its signaling and approval; each session is one dedicated app channel:
///
/// - cmux.rd/1: this bundle's `cmux-screen-sharing serve` (cmux-tui/crates/cmux-rd-host, the
///   host the app's Screen Sharing helper runs) is this worker's child, and the channel is its
///   stdin and stdout. The app drives it exactly as it drives a local host.
/// - WebRTC: this worker's `ScreenStreamHost`, the same host it serves unattached, with the
///   app's signals relayed over the channel.
///
/// Closing the channel ends the session. While any session runs the worker reports
/// `attached` in its status, so the host never restarts or upgrades it under a viewer.
final class AttachedScreenSessions: Sendable {
    /// The cmux.rd/1 host next to this executable, or nil in a bundle without one.
    let rdHost: String?
    let logPath: String
    private let active = OSAllocatedUnfairLock(initialState: 0)
    private let changedBox = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    init(rdHost: String? = AttachedScreenSessions.bundledRdHost(), logPath: String) {
        self.rdHost = rdHost
        self.logPath = logPath
    }

    /// Called (on a session's thread) when a session starts or ends.
    var onChange: (@Sendable () -> Void)? {
        get { changedBox.withLock { $0 } }
        set { changedBox.withLock { $0 = newValue } }
    }

    private func changed() { onChange?() }

    /// `Contents/MacOS/cmux-screen-sharing` beside `cmux-remote`.
    static func bundledRdHost() -> String? {
        guard let directory = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let path = directory.appending(path: "cmux-screen-sharing").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Sessions running now.
    var serving: Int { active.withLock { $0 } }

    /// What this worker serves for the app (its status `serves`).
    var serves: [String] {
        (rdHost == nil ? [] : [AttachedScreenHost.rdKind]) + [AttachedScreenHost.webRTCKind]
    }

    /// A channel's first request, on its reader thread: true when it opened an attached session,
    /// which owns the channel from then on (its thread included).
    func take(_ request: [String: Any], channel: LineChannel) -> Bool {
        switch request["method"] as? String {
        case AttachedScreenHost.rdServe:
            serveRd(id: request["id"], channel: channel)
            return true
        case AttachedScreenHost.webRTCServe:
            serveWebRTC(id: request["id"], params: request["params"] as? [String: Any] ?? [:], channel: channel)
            return true
        default:
            return false
        }
    }

    private func began() {
        active.withLock { $0 += 1 }
        changed()
    }

    private func ended() {
        active.withLock { $0 = max(0, $0 - 1) }
        changed()
    }

    // MARK: cmux.rd/1

    private func serveRd(id: Any?, channel: LineChannel) {
        guard let rdHost else {
            channel.write(RemoteWire.failure(id: id, code: "unavailable", message: "this cmux Remote has no cmux.rd/1 host"))
            return channel.close()
        }
        let child: ChildProcess
        do {
            child = try ChildProcess.spawn(executable: rdHost, arguments: ["serve"],
                                           environment: ProcessInfo.processInfo.environment, logPath: logPath)
        } catch {
            logger.error("cmux.rd/1 host did not start: \(String(describing: error), privacy: .public)")
            channel.write(RemoteWire.failure(id: id, code: "spawn", message: "the screen host could not start: \(error)"))
            return channel.close()
        }
        began()
        logger.info("serving an attached cmux.rd/1 session (pid \(child.pid, privacy: .public))")
        channel.write(RemoteWire.answer(id: id, result: ["pid": Int(child.pid)]))
        // Lines the app sent right after the request belong to the host already.
        _ = LineChannel.writeAll(child.stdin, channel.takeBuffered())
        // Both directions end before the channel's descriptor closes.
        let open = OSAllocatedUnfairLock(initialState: 2)
        let finish: @Sendable () -> Void = {
            if open.withLock({ count -> Bool in
                count -= 1
                return count == 0
            }) { channel.close() }
        }
        // The app's lines to the host; the app ending (or Stop) closes its stdin, which stops it.
        BytePump.forward(from: channel.readDescriptor, to: child.stdin, name: "remote-rd-stdin") {
            Darwin.close(child.stdin)
            finish()
        }
        // The host's lines to the app; its exit ends the channel.
        BytePump.forward(from: child.stdout, to: channel.writeDescriptor, name: "remote-rd-stdout") {
            Darwin.close(child.stdout)
            _ = shutdown(channel.readDescriptor, SHUT_RDWR)
            finish()
        }
        ChildProcess.watch(child.pid, name: "remote-rd-reap") { [self] status in
            logger.info("attached cmux.rd/1 session ended (status \(status, privacy: .public))")
            ended()
        }
    }

    // MARK: WebRTC

    private func serveWebRTC(id: Any?, params: [String: Any], channel: LineChannel) {
        let signaling = AttachedChannelSignaling(channel: channel, servers: AttachedScreenHost.servers(params["ice_servers"]))
        let log: @Sendable (String) -> Void = { line in logger.info("\(line, privacy: .public)") }
        // A request without view_only is View Only: input needs the app to ask for it.
        let host = ScreenStreamHost(name: params["name"] as? String ?? "Mac", viewOnly: params["view_only"] as? Bool ?? true,
                                    backend: { ScreenCaptureBackend(log: log) }, log: log)
        host.onEvent = { event in
            let reply: AttachedScreenHost.Event? = switch event {
            case .viewerConnected: .viewerConnected
            case .viewerEnded: .viewerEnded("the WebRTC viewer left")
            case let .sourceFailed(message): .sourceFailed(message)
            case .waiting, .roomLost: nil
            }
            if let reply { channel.write(RemoteWire.line(reply.fields)) }
        }
        began()
        logger.info("serving an attached WebRTC session")
        channel.write(RemoteWire.answer(id: id, result: [:]))
        // task-owner: the session's signaling; it ends with the app's signaling or this channel.
        Task.detached { try? await host.serve(signaling) }
        // This reader thread feeds the app's signals until the app closes the channel (the session ends).
        while let object = channel.readObject() { signaling.feed(object) }
        signaling.finish()
        host.onEvent = nil
        // Closing the peer connection waits on WebRTC's threads: this is the channel's own thread.
        host.disconnectViewer()
        channel.close()
        ended()
    }
}

/// A WebRTC session's signaling relayed over the app's channel. Closing it tells the app this
/// side's signaling is done and keeps the channel: a connected session outlives its signaling.
final class AttachedChannelSignaling: ScreenSignaling {
    private let channel: LineChannel
    private let servers: [ICEServerConfig]
    private let stream: AsyncThrowingStream<ScreenSignal, any Error>
    private let continuation: AsyncThrowingStream<ScreenSignal, any Error>.Continuation

    init(channel: LineChannel, servers: [ICEServerConfig]) {
        self.channel = channel
        self.servers = servers
        (stream, continuation) = AsyncThrowingStream.makeStream(of: ScreenSignal.self, throwing: (any Error).self,
                                                                bufferingPolicy: .bufferingOldest(512))
    }

    /// One line from the app: a signal, or the end of its signaling.
    func feed(_ object: [String: Any]) {
        if let signal = AttachedScreenHost.signal(object) {
            continuation.yield(signal)
        } else if object["signaling_closed"] != nil {
            continuation.finish()
        }
    }

    func finish() { continuation.finish() }

    func messages() -> AsyncThrowingStream<ScreenSignal, any Error> { stream }

    nonisolated(nonsending) func send(_ signal: ScreenSignal) async throws {
        guard channel.write(RemoteWire.line(AttachedScreenHost.line(signal))) else {
            throw VNCWebRTCError.signaling("the cmux app's channel closed")
        }
    }

    nonisolated(nonsending) func iceServers() async throws -> [ICEServerConfig] { servers }

    func close() {
        channel.write(RemoteWire.line(AttachedScreenHost.signalingClosed))
    }

    var endsSessionOnClose: Bool { true }
}

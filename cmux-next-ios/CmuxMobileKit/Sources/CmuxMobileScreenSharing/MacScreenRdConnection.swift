#if os(iOS) && canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
import CmuxMobileTransport
import CmuxScreenKit
import Foundation

/// A joined Mac's screen over `cmux.rd/1`, the device hub share's protocol (the share host
/// refuses WebRTC offers; the Mac viewer's `MacScreenSession` speaks the same). Rust's
/// `MacScreenRd` makes the session key and the offer, runs the secure link, reassembles the
/// video and carries input; this only moves its offer, answer and candidates over the ticket's
/// signaling, and hands its frames and messages to the streamed-surface model. A view session
/// sends no input (Rust drops it too).
final class MacScreenRdConnection: BrowserStreamConnection, @unchecked Sendable {
    private let rd: MacScreenRd
    private let signaling: any ScreenSignaling
    private let sessionID: String
    private let displayID: UInt32?
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    /// `displayID`: the link's `CGDirectDisplayID` (`a=cmux-rd-display-id`); nil streams the
    /// host's main display.
    init(control: Bool, signaling: any ScreenSignaling, sessionID: String, displayID: UInt32?) throws {
        rd = try MacScreenRd(control: control)
        self.signaling = signaling
        self.sessionID = sessionID
        self.displayID = displayID
    }

    var control: Bool { rd.control() }

    /// Opens the ticket's signaling, offers once the socket says hello, and starts the link with
    /// the host's answer. `sink` hears frames, rd messages and one close.
    func start(sink: any BrowserStreamSink) {
        let closer = MacScreenRdCloser(sink: sink)
        let observer = MacScreenRdObserverBridge(sink: sink, closer: closer, signaling: signaling)
        let rd = rd, signaling = signaling, sessionID = sessionID, displayID = displayID
        // task-owner: this connection's signaling; close() cancels it
        let task = Task {
            let ice = ((try? await signaling.iceServers()) ?? [])
                .map { MacScreenIceServer(urls: $0.urls, username: $0.username, credential: $0.credential) }
            var offered = false
            var connected = false
            do {
                for try await signal in signaling.messages() {
                    switch signal {
                    case .hello:
                        guard !offered else { continue }
                        offered = true
                        try await signaling.send(.offer(rd.offer(display: nil, displayId: displayID, maxWidth: nil, maxFps: 60)))
                    case let .answer(text):
                        guard !connected else { continue }
                        connected = true
                        do {
                            _ = try rd.connect(sessionId: sessionID, answer: text, ice: ice, relayOnly: false,
                                               observer: observer)
                        } catch {
                            // An answer this phone can't use (a WebRTC answer, a bad key) fails the
                            // same way on every ticket: end the session instead of reattaching forever.
                            rd.close()
                            closer.close(code: "refused", reason: String(describing: error))
                            return
                        }
                    case let .candidate(candidate) where candidate.sdpMid == "cmux-rd":
                        rd.addRemoteCandidate(candidate: candidate.candidate)
                    case .bye:
                        rd.close()
                        closer.close(code: "ended", reason: "")
                        return
                    default:
                        continue
                    }
                }
                if !Task.isCancelled, !connected { closer.close(code: "link_failed", reason: "the session socket closed") }
            } catch {
                rd.close()
                if !Task.isCancelled { closer.close(code: "link_failed", reason: String(describing: error)) }
            }
        }
        lock.withLock { self.task = task }
    }

    // MARK: BrowserStreamConnection

    /// rb page messages (`rb.open`, `rb.screen`, `rb.visibility`) mean nothing to a desktop host.
    func send(message: Data) throws {}

    /// The touch surface's rb input; Rust maps it to rd input on the stream's pixels (control only).
    func send(input: Data, mustDeliver: Bool) throws {
        rd.rbInput(json: String(decoding: input, as: UTF8.self))
    }

    /// The phone shows one desktop: no media lane to hand between tabs.
    func setVisible(_ visible: Bool) {}

    func requestKeyframe() { rd.requestKeyframe() }
    func noteDecode(micros: UInt32) { rd.noteDecode(decodeUs: micros) }
    func nowMicros() -> UInt64 { rd.nowUs() }

    func stats() -> BrowserStreamStats {
        let raw = rd.stats()
        var stats = BrowserStreamStats()
        stats.frames = raw.frames
        stats.keyframes = raw.keyframes
        stats.bytes = raw.bytes
        stats.framesLost = raw.framesLost
        stats.clockOffsetMicros = raw.clockOffsetUs
        stats.clockRTTMicros = raw.clockRttUs
        stats.videoTrack = raw.videoTrack
        stats.videoCarrier = raw.videoCarrier
        stats.trackFramesDropped = raw.trackFramesDropped
        stats.trackPacketsRecovered = raw.trackPacketsRecovered
        return stats
    }

    func close() {
        lock.withLock { task }?.cancel()
        rd.close()
        signaling.close()
    }
}

/// The first close of a connection reaches its sink; the rest (the link's own after a `bye`,
/// a cancelled signaling loop) do not.
final class MacScreenRdCloser: @unchecked Sendable {
    private let sink: any BrowserStreamSink
    private let lock = NSLock()
    private var closed = false

    init(sink: any BrowserStreamSink) { self.sink = sink }

    func close(code: String, reason: String) {
        let first = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        if first { sink.browserClosed(code: code, reason: reason) }
    }
}

/// Rust's session events: candidates and the path go to the hub, the rest to the model.
final class MacScreenRdObserverBridge: MacScreenObserver, @unchecked Sendable {
    private let sink: any BrowserStreamSink
    private let closer: MacScreenRdCloser
    private let signaling: any ScreenSignaling

    init(sink: any BrowserStreamSink, closer: MacScreenRdCloser, signaling: any ScreenSignaling) {
        self.sink = sink
        self.closer = closer
        self.signaling = signaling
    }

    func onCandidate(candidate: String) {
        let signaling = signaling
        // task-owner: one candidate frame on the session socket
        Task { try? await signaling.send(.candidate(ScreenICECandidate(candidate: candidate, sdpMid: "cmux-rd", sdpMLineIndex: 0))) }
    }

    func onConnected() {}

    func onPath(kind: String?, rttUs: UInt64?) {
        guard let kind else { return }
        let signaling = signaling
        // task-owner: one path frame (the hub records direct or relay)
        Task { try? await signaling.send(.path(relay: kind.contains("relay"))) }
    }

    func onFrame(frame: BrowserFrame) {
        sink.browserFrame(BrowserStreamFrame(
            stream: frame.stream, frame: frame.frame, keyframe: frame.keyframe, accessUnit: frame.accessUnit,
            captureMicros: frame.captureUs, receivedMicros: frame.receivedUs, ageMicros: frame.ageUs))
    }

    func onMessage(json: String) { sink.browserMessage(Data(json.utf8)) }

    func onClosed(code: String, reason: String) { closer.close(code: code, reason: reason) }
}
#endif

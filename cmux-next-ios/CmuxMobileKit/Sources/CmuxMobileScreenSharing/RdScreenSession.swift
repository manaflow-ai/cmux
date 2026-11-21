#if os(iOS)
import CmuxMobileBrowserStream
import CmuxMobileLinkFFI
import CmuxScreenKit
import CoreGraphics
import Foundation
import os
import QuartzCore

private let log = Logger(subsystem: "dev.cmux.mobile", category: "screen-rd")

/// One screen stream to a cmux.rd/1 host (a Linux desktop) on a device hub session's ticket.
/// The link and the rd viewer core are Rust (`screenOffer`, `ScreenStream` in
/// cmux-mobile-link-ffi); this carries the offer, answer and candidates over the ticket's
/// signaling (which signs this side's offer with the device key and checks the host's
/// answer against the key its ticket names), decodes the access units with VideoToolbox
/// into its layer, and hands input to Rust. ``ScreenSession`` drives it like its other
/// streams: connect, reconnect on a new ticket, input, stats.
@MainActor
final class RdScreenSession: ScreenDesktopStream {
    /// The widest stream and the frame rate the phone asks for: a phone shows a desktop
    /// fitted to its screen, so a wider stream only costs host encode, network and decode.
    static let maxWidth: UInt32 = 1920
    static let maxFps: UInt32 = 60

    private let signaling: any ScreenSignaling
    private let sessionID: String
    private let viewerID: String
    private let control: Bool
    private let decoder = BrowserVideoDecoder()
    /// The Rust stream once the host answered, for the decode queue's callbacks too.
    private let current = OSAllocatedUnfairLock<CmuxMobileLinkFFI.ScreenStream?>(initialState: nil)
    /// The decoded picture's size and the last decode time, written on the decode queue.
    private let decoded = OSAllocatedUnfairLock(initialState: Decoded())
    private var events: (@MainActor (ScreenDesktopEvent) -> Void)?
    private var task: Task<Void, Never>?
    private var closed = false

    private struct Decoded: Sendable {
        var size: CGSize?
        var decodeMicros: UInt32?
    }

    /// What the Rust observer says, hopped to the main actor.
    enum Observed: Sendable {
        case message(String)
        case path(relayed: Bool)
        case closed(String)
        case picture(CGSize)
    }

    var layer: CALayer { decoder.layer }

    init(signaling: any ScreenSignaling, sessionID: String, viewerID: String, control: Bool) {
        self.signaling = signaling
        self.sessionID = sessionID
        self.viewerID = viewerID
        self.control = control
    }

    func start(_ events: @escaping @MainActor (ScreenDesktopEvent) -> Void) {
        guard !closed, task == nil else { return }
        self.events = events
        let post: @Sendable (Observed) -> Void = { [weak self] observed in
            // task-owner: one main-actor hop per link event (not per frame)
            Task { @MainActor in self?.observed(observed) }
        }
        let current = current, decoded = decoded
        decoder.requestKeyframe = { current.withLock { $0 }?.requestKeyframe() }
        decoder.now = { current.withLock { $0 }?.nowUs() ?? 0 }
        decoder.shown = { shown in
            if let stream = current.withLock({ $0 }) {
                stream.noteDecode(decodeUs: shown.decodeMicros)
                stream.notePresented()
            }
            let size = CGSize(width: Int(shown.width), height: Int(shown.height))
            let changed = decoded.withLock { state -> Bool in
                state.decodeMicros = shown.decodeMicros
                defer { state.size = size }
                return state.size != size
            }
            if changed { post(.picture(size)) }
        }
        let observer = RdScreenObserver(decoder: decoder, signaling: signaling, post: post)
        // task-owner: the stream's signaling; close() cancels it
        task = Task { [weak self] in await self?.run(observer: observer) }
    }

    /// Offers once the session socket is open, opens the link on the host's answer, and
    /// hands the host's later candidates to the link. The signaling may close once the link
    /// is up: a connected stream lives on without it.
    private func run(observer: RdScreenObserver) async {
        let offer: ScreenOffer
        do {
            offer = try screenOffer(maxWidth: Self.maxWidth, maxFps: Self.maxFps, display: nil)
        } catch {
            return end("no session key: \(error)")
        }
        var answered = false
        do {
            for try await signal in signaling.messages() {
                guard !closed else { return }
                switch signal {
                case .hello:
                    log.info("rd: offer sent")
                    try await signaling.send(.offer(offer.text()))
                case let .answer(text) where !answered:
                    answered = true
                    log.info("rd: answer received; opening the link")
                    let iceServers = try await signaling.iceServers()
                    let servers = try JSONEncoder().encode(iceServers)
                    let stream = try await offer.answer(
                        answer: text, sessionId: sessionID, viewerId: viewerID,
                        iceServersJson: String(decoding: servers, as: UTF8.self), relayOnly: false,
                        control: control, observer: observer)
                    guard !closed else {
                        stream.close()
                        return
                    }
                    current.withLock { $0 = stream }
                case let .candidate(candidate) where candidate.sdpMid == RdScreenObserver.mid:
                    try? current.withLock({ $0 })?.addCandidate(candidate: candidate.candidate)
                case .bye:
                    return end("the computer ended the session")
                default:
                    continue
                }
            }
            if !answered, !closed { end("the session closed before the computer answered") }
        } catch {
            guard !closed else { return }
            log.error("rd: \(String(describing: error), privacy: .public)")
            end(String(describing: error))
        }
    }

    private func observed(_ observed: Observed) {
        guard !closed else { return }
        switch observed {
        case let .message(json):
            guard let data = json.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  message["t"] as? String == "welcome", let stats = current.withLock({ $0 })?.stats() else { return }
            log.info("rd: welcome \(stats.width)x\(stats.height) \(stats.encoder, privacy: .public)")
            events?(.connected(width: Int(stats.width), height: Int(stats.height)))
        case let .path(relayed):
            events?(.path(relayed: relayed))
        case let .picture(size):
            events?(.picture(size))
        case let .closed(reason):
            log.info("rd: closed: \(reason, privacy: .public)")
            end(reason)
        }
    }

    func send(_ input: ScreenDesktopInput) {
        guard let stream = current.withLock({ $0 }) else { return }
        let event: [String: Any] = switch input {
        case let .pointer(x, y): ["e": "pointer", "x": x, "y": y]
        case let .button(button, down): ["e": "button", "button": button, "down": down]
        case let .scroll(dx, dy): ["e": "scroll", "dx": dx, "dy": dy, "precise": false]
        case let .keysym(key, down): ["e": "keysym", "k": Int(key.rawValue), "down": down]
        case let .type(text): ["e": "type", "text": text]
        }
        guard let json = try? JSONSerialization.data(withJSONObject: event) else { return }
        do { try stream.sendInput(json: String(decoding: json, as: UTF8.self)) } catch {
            // A view-only session refuses input; nothing else to do with it here.
            log.debug("rd: input not sent: \(String(describing: error), privacy: .public)")
        }
    }

    func requestKeyframe() {
        current.withLock { $0 }?.requestKeyframe()
    }

    func sample() -> ScreenDesktopSample {
        guard let stats = current.withLock({ $0 })?.stats() else { return ScreenDesktopSample() }
        let decodeMicros = decoded.withLock { $0.decodeMicros }
        let rttMicros = stats.path?.rttUs ?? stats.clockRttUs.map(UInt64.init)
        return ScreenDesktopSample(framesReceived: stats.frames, framesShown: stats.presented, framesLost: stats.framesLost,
                                   bytes: stats.bytes, roundTripMs: rttMicros.map { Double($0) / 1000 },
                                   decodeMs: decodeMicros.map { Double($0) / 1000 }, encoding: "H264 HW")
    }

    func close() {
        guard !closed else { return }
        teardown()
    }

    /// The stream ended on its own: the session hears why once.
    private func end(_ reason: String) {
        guard !closed else { return }
        let events = events
        teardown()
        events?(.ended(reason))
    }

    private func teardown() {
        closed = true
        events = nil
        task?.cancel()
        task = nil
        // The host hears `stop` over the link; the hub hears the viewer's own /end.
        current.withLock { stream in
            stream?.close()
            stream = nil
        }
        signaling.close()
    }
}

/// The Rust stream's observer, on the library's threads: frames go straight to the decode
/// queue, the link's candidates and path to the signaling socket, the rest to the session
/// on the main actor.
final class RdScreenObserver: ScreenObserver {
    /// The signaling `sdpMid` of cmux.rd/1 candidates.
    static let mid = "cmux-rd"

    private let decoder: BrowserVideoDecoder
    private let signaling: any ScreenSignaling
    private let post: @Sendable (RdScreenSession.Observed) -> Void

    init(decoder: BrowserVideoDecoder, signaling: any ScreenSignaling, post: @escaping @Sendable (RdScreenSession.Observed) -> Void) {
        self.decoder = decoder
        self.signaling = signaling
        self.post = post
    }

    func onFrame(frame: BrowserFrame) {
        decoder.submit(frame: frame.frame, accessUnit: frame.accessUnit, keyframe: frame.keyframe,
                       receivedMicros: frame.receivedUs, ageMicros: frame.ageUs)
    }

    func onCandidate(candidate: String) {
        let signaling = signaling
        // task-owner: one signaling send; the link keeps going whether it lands or not
        Task { try? await signaling.send(.candidate(ScreenICECandidate(candidate: candidate, sdpMid: Self.mid, sdpMLineIndex: 0))) }
    }

    func onPath(path: ScreenPath) {
        let signaling = signaling
        // task-owner: one signaling send (the hub records the session's path)
        Task { try? await signaling.send(.path(relay: path.relayed)) }
        post(.path(relayed: path.relayed))
    }

    func onMessage(json: String) {
        post(.message(json))
    }

    func onClosed(reason: String) {
        post(.closed(reason))
    }
}
#endif

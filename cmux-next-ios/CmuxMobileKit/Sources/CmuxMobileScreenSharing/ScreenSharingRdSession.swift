#if os(iOS)
import AVFoundation
import CmuxMobileBrowserStream
import CmuxMobileLinkFFI
public import CmuxScreenKit
public import CoreGraphics
public import Foundation
public import Observation
import os

private let log = Logger(subsystem: "dev.cmux.mobile", category: "screen-rd")

/// One approved Screen Sharing session on cmux.rd/1, the protocol the Mac's own viewer speaks
/// and every host serves: a Linux desktop and a joined Mac's daemon serve nothing else. The
/// ticket's signaling carries this phone's signed offer and the host's signed answer, as on
/// the Mac (`MacScreenSession`); the link, reassembly, feedback and input are the shared Rust
/// (`ScreenLink`, cmux-mobile-link-ffi `screen.rs`); the picture is VideoToolbox into a layer
/// (`BrowserVideoDecoder`, the streamed browser tab's decoder).
@MainActor @Observable
public final class ScreenSharingRdSession {
    public enum Phase: Equatable, Sendable {
        case connecting
        /// The first picture is on screen.
        case streaming
        /// Over: the host's own reason, the link's failure, or this side's close.
        case ended(String)
    }

    public private(set) var phase: Phase = .connecting
    /// The stream's size in pixels (the host's `welcome`), zero before it.
    public private(set) var frameSize: CGSize = .zero
    /// Capture on the host to shown here, for the newest frame (when the clocks agree).
    public private(set) var latencyMs: Double?
    /// The path the link rides (`direct_lan`, `direct_wan`, `turn_relay`).
    public private(set) var path: String?
    /// Start to first picture, once shown.
    public private(set) var firstFrameMs: Double?
    /// Full Control: touches click and type on the host.
    public let control: Bool

    @ObservationIgnored public let decoder = BrowserVideoDecoder()
    @ObservationIgnored private let link: ScreenLink?
    @ObservationIgnored private let signaling: any ScreenSignaling
    @ObservationIgnored private let relayOnly: Bool
    @ObservationIgnored private let wish: (maxWidth: UInt32?, maxFps: UInt32?)
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var started = ContinuousClock.now
    @ObservationIgnored private var answered = false
    @ObservationIgnored private var closed = false

    /// `maxWidth`: the phone screen's long edge in pixels (Auto sends no more than it can show).
    public init(signaling: any ScreenSignaling, control: Bool, relayOnly: Bool = false, maxWidth: Int?, maxFps: Int?) {
        self.signaling = signaling
        self.control = control
        self.relayOnly = relayOnly
        wish = (maxWidth.map { UInt32(clamping: $0) }, maxFps.map { UInt32(clamping: $0) })
        link = try? ScreenLink()
    }

    /// Opens the session: the signaling socket, the offer once it is open, the link on the answer.
    public func connect() {
        guard let link else {
            phase = .ended(String(localized: "Screen Sharing couldn't start on this iPhone."))
            return
        }
        started = .now
        let decoder = decoder
        decoder.requestKeyframe = { [weak link] in link?.requestKeyframe() }
        decoder.now = { [weak link] in link?.nowUs() ?? 0 }
        decoder.shown = { [weak self, weak link] shown in
            link?.noteDecode(decodeUs: shown.decodeMicros)
            let latency = shown.latencyMicros.map { Double($0) / 1000 }
            Task { @MainActor [weak self] in self?.frameShown(latencyMs: latency) }
        }
        #if DEBUG
        // Test-only key-to-frame probe (CMUX_K2F_MARKER set by the latency UITest).
        if control, let probe = ScreenKeyToFrame() {
            probe.start(decoder: decoder, input: RdProbeInput(link: link),
                        meta: ["viewer": "cmux-next-ios", "path": "rd",
                               "present": "next vsync after the layer took the picture (estimate)"])
        }
        #endif
        let signaling = signaling
        tasks.append(Task { [weak self] in await self?.follow(signaling, link: link) })
    }

    /// Ends the session here (the viewer tells the hub).
    public func close() {
        guard !closed else { return }
        closed = true
        for task in tasks { task.cancel() }
        tasks.removeAll()
        link?.close()
        signaling.close()
        decoder.reset()
        if case .ended = phase {} else { phase = .ended(String(localized: "Disconnected")) }
    }

    // MARK: Input (stream pixels)

    /// A tap: the pointer goes there and clicks.
    public func click(at point: CGPoint, button: UInt8 = 1) {
        guard control, let link else { return }
        link.pointer(x: Int32(point.x), y: Int32(point.y))
        link.button(button: button, down: true)
        link.button(button: button, down: false)
    }

    public func movePointer(to point: CGPoint) {
        guard control else { return }
        link?.pointer(x: Int32(point.x), y: Int32(point.y))
    }

    public func press(_ down: Bool, button: UInt8 = 1) {
        guard control else { return }
        link?.button(button: button, down: down)
    }

    /// Scroll by points (precise, the host's pixel scroll).
    public func scroll(dx: CGFloat, dy: CGFloat) {
        guard control else { return }
        link?.scroll(dx: Int32((dx * 100).rounded()), dy: Int32((dy * 100).rounded()), precise: true)
    }

    public func type(_ text: String) {
        guard control, !text.isEmpty else { return }
        link?.text(text: text)
    }

    /// A USB HID usage (page 7) tapped: Delete is 0x2A, Return 0x28, Escape 0x29, Tab 0x2B.
    public func tapKey(usage: UInt32) {
        guard control, let link else { return }
        link.keyEvent(usage: usage, down: true)
        link.keyEvent(usage: usage, down: false)
    }

    // MARK: Internals

    private func follow(_ signaling: any ScreenSignaling, link: ScreenLink) async {
        let servers = (try? await signaling.iceServers()) ?? []
        let ice = (try? JSONEncoder().encode(servers)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let sessionID = (signaling as? TicketSignaling)?.ticket.sessionID ?? UUID().uuidString
        let offer = link.offer(display: nil, maxWidth: wish.maxWidth, maxFps: wish.maxFps)
        do {
            for try await signal in signaling.messages() {
                guard !Task.isCancelled else { return }
                switch signal {
                case .hello:
                    // The session socket is open: the offer goes now (the host answers it).
                    try await signaling.send(.offer(offer))
                case let .answer(text) where !answered:
                    answered = true
                    let answer = ScreenAnswer(session: sessionID, answer: text, iceJson: ice, control: control, relayOnly: relayOnly)
                    let observer = RdObserver(session: self, decoder: decoder, signaling: signaling)
                    do {
                        _ = try link.start(answer: answer, observer: observer)
                    } catch {
                        log.error("screen rd: the answer did not start the link: \(String(describing: error), privacy: .public)")
                        end(String(localized: "The computer answered in a way this iPhone can't use."))
                        return
                    }
                case let .candidate(candidate) where candidate.sdpMid == "cmux-rd":
                    link.addCandidate(candidate: candidate.candidate)
                case .bye:
                    end(String(localized: "The computer ended the session."))
                    return
                default:
                    continue
                }
            }
        } catch {
            if phase == .connecting { end(String(localized: "The session couldn't reach the computer.")) }
        }
    }

    fileprivate func message(_ json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
        switch object["t"] as? String {
        case "welcome":
            if let width = object["width"] as? Int, let height = object["height"] as? Int, width > 0, height > 0 {
                frameSize = CGSize(width: width, height: height)
            }
        case "path":
            path = object["kind"] as? String
            if let kind = path {
                let relay = kind == "turn_relay" || kind == "do_relay" || kind == "via_cloud_region"
                let signaling = signaling
                // task-owner: one best-effort path report to the hub (`sessions.path`)
                Task { try? await signaling.send(.path(relay: relay)) }
            }
        default:
            break
        }
    }

    fileprivate func frameShown(latencyMs: Double?) {
        if let latencyMs { self.latencyMs = latencyMs }
        guard phase == .connecting else { return }
        let elapsed = ContinuousClock.now - started
        firstFrameMs = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        log.info("screen rd: first picture in \(self.firstFrameMs ?? -1, privacy: .public) ms")
        phase = .streaming
    }

    fileprivate func end(_ reason: String) {
        guard !closed else { return }
        if case .ended = phase { return }
        phase = .ended(reason)
    }
}

/// The link thread's callbacks: frames straight to the decoder's queue, the rest to the main actor.
private final class RdObserver: ScreenObserver, @unchecked Sendable {
    private weak var session: ScreenSharingRdSession?
    private let decoder: BrowserVideoDecoder
    private let signaling: any ScreenSignaling

    init(session: ScreenSharingRdSession, decoder: BrowserVideoDecoder, signaling: any ScreenSignaling) {
        self.session = session
        self.decoder = decoder
        self.signaling = signaling
    }

    func onFrame(frame: BrowserFrame) {
        decoder.submit(frame: frame.frame, accessUnit: frame.accessUnit, keyframe: frame.keyframe,
                       receivedMicros: frame.receivedUs, ageMicros: frame.ageUs)
    }

    func onCandidate(candidate: String) {
        let signaling = signaling
        // task-owner: one trickled route to the host on the session's signaling
        Task { try? await signaling.send(.candidate(ScreenICECandidate(candidate: candidate, sdpMid: "cmux-rd", sdpMLineIndex: 0))) }
    }

    func onMessage(json: String) {
        Task { @MainActor [weak session] in session?.message(json) }
    }

    func onClosed(reason: String) {
        Task { @MainActor [weak session] in session?.end(ScreenSharingRdSession.endedText(reason)) }
    }
}

extension ScreenSharingRdSession {
    /// The words for the link's end reason: the host's own (`host: ...`) as it said it.
    nonisolated static func endedText(_ reason: String) -> String {
        if reason.hasPrefix("host: ") {
            let host = String(reason.dropFirst("host: ".count))
            return host.hasPrefix("failed")
                ? String(localized: "The computer couldn't share its screen: \(host)")
                : String(localized: "The computer ended the session.")
        }
        if reason.hasPrefix("link failed") { return String(localized: "The connection to the computer was lost.") }
        return String(localized: "Disconnected")
    }
}

#if DEBUG
/// The key-to-frame probe's input on the rd link: the same calls a tap and the keyboard make.
private final class RdProbeInput: KeyToFrameInput {
    private let link: ScreenLink
    init(link: ScreenLink) { self.link = link }

    func key() {
        link.keyEvent(usage: 0x04, down: true) // HID "a", as `cmux-rd bench --input key`
        link.keyEvent(usage: 0x04, down: false)
    }

    func click(x: UInt32, y: UInt32) {
        link.pointer(x: Int32(clamping: x), y: Int32(clamping: y))
        link.button(button: 1, down: true)
        link.button(button: 1, down: false)
    }
}
#endif
#endif

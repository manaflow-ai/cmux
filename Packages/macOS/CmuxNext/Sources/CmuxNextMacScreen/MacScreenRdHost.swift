import CmuxNextCompat
import CmuxScreenKit
import CoreGraphics
import Foundation
import os

/// This Mac serving one approved device hub session on cmux.rd/1
/// (plans/cmux-next/remote-desktop-mac-host.md section 7): `cmux rd serve`
/// captures, encodes and injects input, and holds the secure link; this object
/// carries its offer, answer and candidates over the session's signaling. The
/// app is the process's responsible process, so the Screen Recording and
/// Accessibility grants the person gave cmux apply to it.
nonisolated final class MacScreenRdHost: Sendable {
    enum Event: Sendable, Equatable {
        /// The viewer's link is up: it sees (and, in a control session, controls) the screen.
        case viewerConnected
        /// The session ended (the viewer left, the link failed, or Stop).
        case viewerEnded(String)
        /// The host could not start (no capture permission, no display).
        case sourceFailed(String)
    }

    struct Session: Sendable {
        var id: String
        var viewerID: String
        var viewOnly: Bool
        var servers: MacScreenRdServers
    }

    private let session: Session
    private let process = MacScreenRdProcess()
    private let handler = Mutex<(@Sendable (Event) -> Void)?>(nil)
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mac-screen-rd-host")

    init(session: Session) {
        self.session = session
    }

    var onEvent: (@Sendable (Event) -> Void)? {
        get { handler.withLock { $0 } }
        set { handler.withLock { $0 = newValue } }
    }

    private func emit(_ event: Event) {
        handler.withLock { $0 }?(event)
    }

    /// Serves the session until it ends: waits for the viewer's offer, starts the host, answers with
    /// this side's session key, displays and candidates, and relays candidates both ways.
    func serve(_ signaling: any ScreenSignaling) async throws {
        var started = false
        let session = self.session
        let process = self.process
        // task-owner: the host's output for this session; ends with the process
        let output = Task { [weak self] in
            var answered = false
            var answer: MacScreenRdDocument?
            var connected = false
            for await line in process.lines {
                guard let self else { return }
                if let displays = line.displays {
                    var document = answer ?? MacScreenRdDocument(key: "")
                    document.displays = displays.compactMap { $0.count == 2 ? CGSize(width: Double($0[0]), height: Double($0[1])) : nil }
                    document.currentDisplay = line.current
                    answer = document
                }
                if let key = line.key {
                    var document = answer ?? MacScreenRdDocument(key: key)
                    document.key = key
                    answer = document
                }
                if let candidate = line.candidate {
                    if answered {
                        try? await signaling.send(.candidate(ScreenICECandidate(candidate: candidate, sdpMid: "cmux-rd", sdpMLineIndex: 0)))
                    } else {
                        answer?.candidates.append(candidate)
                    }
                }
                // The answer goes once every candidate this side will find is known.
                if line.candidatesDone == true, !answered, let document = answer {
                    answered = true
                    do { try await signaling.send(.answer(document.text)) } catch {
                        logger.error("answer not sent: \(String(describing: error), privacy: .public)")
                    }
                }
                if line.connected == true, !connected {
                    connected = true
                    emit(.viewerConnected)
                }
                if let path = line.path, let kind = path.kind {
                    try? await signaling.send(.path(relay: kind.contains("relay") || kind == "via_cloud_region"))
                }
                if let reason = line.ended {
                    emit(connected ? .viewerEnded(reason) : .sourceFailed(reason))
                    return
                }
            }
            // The process ended without saying why (it crashed, or never started).
            self?.emit(.sourceFailed(process.stderrTail.isEmpty ? "the screen host stopped" : process.stderrTail))
        }
        defer { output.cancel() }
        for try await signal in signaling.messages() {
            switch signal {
            case let .offer(text):
                guard !started, let offer = MacScreenRdDocument(text: text) else { continue }
                started = true
                do { try process.start(.serve) } catch {
                    emit(.sourceFailed("the screen host could not start: \(error.localizedDescription)"))
                    return
                }
                process.send(Setup(session: session.id, peerKey: offer.key,
                                   viewer: Setup.Viewer(user: session.viewerID, install: session.viewerID),
                                   scope: session.viewOnly ? "view" : "control", stun: session.servers.stun,
                                   display: offer.display.map(String.init) ?? "main", maxFps: offer.maxFps.map { min($0, 120) },
                                   maxWidth: offer.maxWidth))
                for candidate in offer.candidates { process.send(Later(candidate: candidate)) }
            case let .candidate(candidate) where candidate.sdpMid == "cmux-rd":
                process.send(Later(candidate: candidate.candidate))
            case .bye:
                process.stop()
                return
            default:
                continue
            }
        }
    }

    /// Stop: the host stops its session (the viewer sees the link close) and exits.
    func disconnectViewer() {
        process.stop()
    }

    private struct Setup: Encodable {
        struct Viewer: Encodable {
            var user: String
            var install: String
        }

        var session: String
        var peerKey: String
        var viewer: Viewer
        var scope: String
        var stun: [String]
        var display: String
        var maxFps: Int?
        var maxWidth: Int?

        enum CodingKeys: String, CodingKey {
            case session, viewer, scope, stun, display
            case peerKey = "peer_key"
            case maxFps = "max_fps"
            case maxWidth = "max_width"
        }
    }

    private struct Later: Encodable {
        var candidate: String
    }
}

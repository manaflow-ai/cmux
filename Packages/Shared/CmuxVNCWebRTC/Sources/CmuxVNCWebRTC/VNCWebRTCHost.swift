import Foundation
import Network

/// The Mac side: holds the room open, answers each viewer, and pipes the
/// viewer's `rfb` data channel to a VNC server over TCP (by default this
/// Mac's Screen Sharing, 127.0.0.1:5900). One viewer at a time; a new one
/// replaces the old. The VNC server still authenticates the viewer.
public final class VNCWebRTCHost: @unchecked Sendable {
    // @unchecked: `current` is behind `lock`.
    public let pairing: VNCPairing
    public let targetHost: String
    public let targetPort: UInt16
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var current: (link: VNCPeerLink, tcp: NWConnection?, task: Task<Void, Never>)?

    public init(pairing: VNCPairing, targetHost: String = "127.0.0.1", targetPort: UInt16 = 5900,
                log: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.pairing = pairing
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.log = log
    }

    /// Serves until cancelled, reconnecting to the room when it drops.
    public func run() async {
        var delay = 1.0
        while !Task.isCancelled {
            do {
                try await serveRoom()
                delay = 1
            } catch {
                log("room connection lost: \(error); retrying in \(Int(delay)) s")
            }
            try? await Task.sleep(for: .seconds(delay)) // reconnect backoff
            delay = min(delay * 2, 30)
        }
    }

    private func serveRoom() async throws {
        let socket = SignalSocket(pairing: pairing, role: "host")
        defer { socket.close() }
        for try await message in socket.messages() {
            switch message.type {
            case "hello":
                log("waiting for a viewer in room \(pairing.room.prefix(8))…")
            case "offer":
                guard let sdp = message.sdp else { continue }
                try await accept(offer: sdp, socket: socket)
            case "candidate":
                await lock.withLock({ current?.link })?.add(candidate: message)
            case "peer-left":
                log("viewer left")
                endCurrent()
            default:
                break
            }
        }
    }

    private func accept(offer sdp: String, socket: SignalSocket) async throws {
        endCurrent()
        let link = try VNCPeerLink(iceServers: try await SignalSocket.iceServers(pairing))
        let task = Task { [weak self] in
            for await event in link.events {
                switch event {
                case let .candidate(message): try? await socket.send(message)
                case .open: self?.bridge(link)
                case let .message(data): self?.forwardToServer(data, from: link)
                case .closed: self?.end(link)
                }
            }
        }
        lock.withLock { current = (link, nil, task) }
        let answer = try await link.answer(offer: sdp)
        try await socket.send(SignalMessage(type: "answer", sdp: answer))
        log("viewer offered; answered")
    }

    /// The channel opened: connect to the VNC server and pipe server bytes back.
    private func bridge(_ link: VNCPeerLink) {
        let tcp = NWConnection(host: NWEndpoint.Host(targetHost), port: NWEndpoint.Port(rawValue: targetPort) ?? 5900, using: .tcp)
        guard lock.withLock({ () -> Bool in
            guard current?.link === link else { return false }
            current?.tcp = tcp
            return true
        }) else { return }
        log("channel open; connecting to \(targetHost):\(targetPort)")
        tcp.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.end(link) }
            if case .cancelled = state { self?.end(link) }
        }
        tcp.start(queue: .global(qos: .userInitiated))
        pump(tcp, to: link)
    }

    private func pump(_ tcp: NWConnection, to link: VNCPeerLink) {
        tcp.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task {
                    do {
                        try await link.send(data)
                        if !complete && error == nil { self.pump(tcp, to: link) } else { self.end(link) }
                    } catch {
                        self.end(link)
                    }
                }
            } else if complete || error != nil {
                end(link)
            } else {
                pump(tcp, to: link)
            }
        }
    }

    private func forwardToServer(_ data: Data, from link: VNCPeerLink) {
        // The channel may deliver before TCP is up: NWConnection queues sends until ready.
        guard let tcp = lock.withLock({ current?.link === link ? current?.tcp : nil }) else { return }
        tcp.send(content: data, completion: .idempotent)
    }

    private func end(_ link: VNCPeerLink) {
        let ended = lock.withLock { () -> (NWConnection?, Task<Void, Never>)? in
            guard let current, current.link === link else { return nil }
            self.current = nil
            return (current.tcp, current.task)
        }
        guard let ended else { return }
        ended.0?.cancel()
        ended.1.cancel()
        link.close()
        log("session ended")
    }

    private func endCurrent() {
        if let link = lock.withLock({ current?.link }) { end(link) }
    }
}

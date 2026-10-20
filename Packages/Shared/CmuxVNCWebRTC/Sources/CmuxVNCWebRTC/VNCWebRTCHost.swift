import Foundation
import Network

/// The Mac side: holds the room open, answers each viewer, and pipes the
/// viewer's `rfb` data channel to a VNC server over TCP (by default this
/// Mac's Screen Sharing, 127.0.0.1:5900). One viewer at a time; a new one
/// replaces the old. The VNC server still authenticates the viewer.
// crash-allow: `current` and the byte counters are read and written only under `lock`; the rest are `let`s.
public final class VNCWebRTCHost: @unchecked Sendable {
    // @unchecked: `current` is behind `lock`.
    public let pairing: VNCPairing
    public let targetHost: String
    public let targetPort: UInt16
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var current: (link: VNCPeerLink, tcp: NWConnection?, task: Task<Void, Never>)?
    /// Bytes from the VNC server to the viewer, and the other way, this session.
    private var serverBytes = 0
    private var viewerBytes = 0

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
                if let sdp = message.candidate {
                    // Type and address class only (no addresses): why a path is or is not direct.
                    let parts = sdp.split(separator: " ")
                    let address = parts.count > 4 ? String(parts[4]) : "?"
                    let kind = address.hasPrefix("10.") || address.hasPrefix("192.168.") || address.hasPrefix("172.") ? "private"
                        : address.contains(":") ? "ipv6" : address.hasSuffix(".local") ? "mdns" : "public"
                    let octets = address.split(separator: ".").compactMap { Int($0) }
                    let officeLAN = octets.count == 4 && octets[0] == 172 && octets[1] == 20 && (20 ... 23).contains(octets[2])
                    log("viewer candidate: \(VNCPeerLink.type(of: sdp)) \(parts.count > 2 ? String(parts[2]).lowercased() : "?") \(kind)\(kind == "private" ? (officeLAN ? " same-LAN" : " other-LAN") : "")")
                }
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
                case .open:
                    self?.bridge(link)
                    self?.startMetrics(link)
                case let .message(data): self?.forwardToServer(data, from: link)
                case .closed: self?.end(link)
                case .video: break
                case let .path(local, remote): self?.log("path: this Mac \(local) ↔ viewer \(remote)\(local == "relay" || remote == "relay" ? " (TURN relay)" : " (direct)")")
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
                lock.withLock { serverBytes += data.count }
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
        guard let tcp = lock.withLock({ () -> NWConnection? in
            guard current?.link === link else { return nil }
            viewerBytes += data.count
            return current?.tcp
        }) else { return }
        tcp.send(content: data, completion: .idempotent)
    }

    /// Every 2 s while `link` is the session: RTT, bandwidth estimate, backlog,
    /// and the Mac's VNC output rate (`metrics:` lines in the host log).
    private func startMetrics(_ link: VNCPeerLink) {
        lock.withLock {
            serverBytes = 0
            viewerBytes = 0
        }
        Task { [weak self] in
            var last = 0
            while let self, lock.withLock({ current?.link === link }) {
                try? await Task.sleep(for: .seconds(2)) // sampling period
                let m = await link.metrics()
                let (server, viewer) = lock.withLock { (serverBytes, viewerBytes) }
                let rate = Double(server - last) / 2 / 1024
                last = server
                func f(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "-" }
                log("metrics: rtt \(f(m.rttMs)) ms, est \(f(m.availableOutgoingKbps)) kbit/s, server→viewer \(String(format: "%.0f", rate)) KB/s (\(server / 1024) KB total), backlog \(m.backlogBytes / 1024) KB, viewer→server \(viewer) B")
            }
        }
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

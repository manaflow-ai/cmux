import Foundation

/// Checks a TURN relay the way a session uses it: a relay-only peer
/// connection gathers candidates from `servers`, and the relay works when a
/// `typ relay` candidate arrives before `timeout`. Nothing is sent to a peer.
public struct ICERelayCheck: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// The relay allocated an address (`typ relay` candidate).
        case relayed
        /// No relay candidate before the deadline: wrong credentials, an
        /// unreachable server, or a blocked port.
        case noRelayCandidate
        case failed(String)
    }

    public let servers: [ICEServerConfig]
    public let timeout: Duration

    public init(servers: [ICEServerConfig], timeout: Duration = .seconds(10)) {
        self.servers = servers
        self.timeout = timeout
    }

    public func run() async -> Outcome {
        guard !servers.isEmpty else { return .noRelayCandidate }
        let link: VNCPeerLink
        do { link = try VNCPeerLink(iceServers: servers, relayOnly: true, preferStreamRelays: false) } catch {
            return .failed("\(error)")
        }
        defer { link.close() }
        let timeout = timeout
        return await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                for await event in link.events {
                    if case let .candidate(message) = event, let line = message.candidate,
                       Self.isRelayCandidate(line) {
                        return .relayed
                    }
                }
                return .noRelayCandidate
            }
            group.addTask {
                do { _ = try await link.offer(label: "relay-check") } catch { return .failed("\(error)") }
                try? await Task.sleep(for: timeout) // the check's deadline
                return .noRelayCandidate
            }
            let first = await group.next() ?? .noRelayCandidate
            group.cancelAll()
            return first
        }
    }

    /// Whether an ICE candidate line is a relay (TURN) candidate.
    public static func isRelayCandidate(_ line: String) -> Bool {
        VNCPeerLink.type(of: line) == "relay"
    }
}

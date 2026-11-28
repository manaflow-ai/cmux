import Foundation

/// Checks a TURN relay the way a session uses it: a relay-only peer
/// connection gathers candidates from `servers`, and the relay works when a
/// `typ relay` candidate arrives before `timeout`. Nothing is sent to a peer.
public struct ICERelayCheck: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// The relay allocated an address (`typ relay` candidate).
        case relayed
        /// No relay candidate before the deadline, and no error from the server.
        case noRelayCandidate
        /// The TURN server refused the credentials (401).
        case refusedCredentials
        /// The TURN server could not be reached (WebRTC 701).
        case unreachable
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
        let errors = ErrorLog()
        link.onCandidateError = { error in if error.isTURN { errors.add(error) } }
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
            return first == .noRelayCandidate ? Self.outcome(errors.all) : first
        }
    }

    /// Why no relay candidate came, from the TURN servers' errors: a 401
    /// is refused credentials; anything else (a 701, or silence until the
    /// deadline, as a blackholed UDP port gives) is a relay that can't be reached.
    public static func outcome(_ errors: [ICECandidateError]) -> Outcome {
        if errors.contains(where: \.refusedCredentials) { return .refusedCredentials }
        return .unreachable
    }

    /// Errors from WebRTC's threads.
    // crash-allow: `errors` is read and written only inside `lock.withLock`.
    private final class ErrorLog: @unchecked Sendable {
        // @unchecked: `errors` is behind `lock`.
        private let lock = NSLock()
        private var errors: [ICECandidateError] = []
        func add(_ error: ICECandidateError) { lock.withLock { errors.append(error) } }
        var all: [ICECandidateError] { lock.withLock { errors } }
    }

    /// Whether an ICE candidate line is a relay (TURN) candidate.
    public static func isRelayCandidate(_ line: String) -> Bool {
        VNCPeerLink.type(of: line) == "relay"
    }
}

/// One `icecandidateerror`: a STUN or TURN server that gave no candidate.
public struct ICECandidateError: Sendable, Equatable {
    /// The STUN/TURN error code: 401 refused credentials; 701 the server
    /// could not be reached (WebRTC's own code).
    public var code: Int
    /// The server's URL as configured (no credentials).
    public var url: String
    public var text: String

    public init(code: Int, url: String, text: String) {
        self.code = code
        self.url = url
        self.text = text
    }

    /// The server refused the credentials (TURN 401, or 403 for a disallowed peer).
    public var refusedCredentials: Bool { code == 401 || code == 403 }
    /// The server could not be reached (WebRTC 701, or a TURN server error).
    public var unreachable: Bool { code == 701 || (code >= 500 && code < 600) }
    /// Whether this is a TURN server's error (STUN errors don't matter for a relay).
    public var isTURN: Bool { url.hasPrefix("turn:") || url.hasPrefix("turns:") }
}

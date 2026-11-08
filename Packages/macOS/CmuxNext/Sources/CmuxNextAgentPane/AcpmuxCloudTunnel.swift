public import Foundation

/// This Mac's Cloud tunnel through this app's acpmux: `_acpmux/machine.tunnel.attach`, `.detach`
/// and `.rekey` (acpmux `machine_tunnel.rs`). The daemon makes the platform calls and, for a
/// rekey, the new WireGuard key in the process that holds it. The app lends the signed-in
/// person's access token for that one call, and only on a connection whose person proof acpmux
/// took (``AcpmuxPersonLine``); a line without it never sees the token.
@MainActor public struct AcpmuxCloudTunnel {
    public enum Verb: Sendable {
        case attach, detach, rekey

        /// The acpmux method, spelled out for the protocol check.
        public var method: String {
            switch self {
            case .attach: "_acpmux/machine.tunnel.attach"
            case .detach: "_acpmux/machine.tunnel.detach"
            case .rekey: "_acpmux/machine.tunnel.rekey"
            }
        }
    }

    /// A tunnel call that did not run: acpmux's own words when it refused, else `fallback`.
    public struct Refusal: LocalizedError {
        public let errorDescription: String?
    }

    public typealias Open = @MainActor () async -> (any AgentDialogLine)?

    private let open: Open
    private let fallback: String

    /// `open` makes the connection; `fallback` is the text when no acpmux took the call.
    public init(open: @escaping Open, fallback: String) {
        self.open = open
        self.fallback = fallback
    }

    /// How long one tunnel call's connection lives: the whole daemon operation, not a person
    /// line's usual few seconds. An attach may first finish a pending rekey (two platform calls
    /// of up to 10 s each) and a rekey starts the mesh again, so a short line would show a failure
    /// while acpmux still changes the tunnel. Classic's tunnel calls allowed the same 60 s.
    public static let deadline: Duration = .seconds(60)

    /// This app's acpmux at `environment` (nil: none runs), each call's line living `deadline`.
    public init(_ environment: AcpmuxEnvironment?, deadline: Duration = Self.deadline, fallback: String) {
        self.init(open: {
            guard let environment else { return nil }
            return await AcpmuxPersonLine.open(environment, deadline: deadline)
        }, fallback: fallback)
    }

    /// One call with `token` (and, for attach and detach, the team network `networkID`); the
    /// daemon's answer.
    @discardableResult
    public func run(_ verb: Verb, token: String, networkID: String? = nil) async throws -> [String: Any] {
        guard let line = await open() else { throw Refusal(errorDescription: fallback) }
        defer { line.close() }
        guard line.isPerson else { throw Refusal(errorDescription: fallback) }
        var params: [String: Any] = ["token": token]
        if let networkID, verb != .rekey { params["networkId"] = networkID }
        guard let reply = await line.call(verb.method, params) else {
            throw Refusal(errorDescription: line.lastError.flatMap { $0.isEmpty ? nil : $0 } ?? fallback)
        }
        return reply
    }
}

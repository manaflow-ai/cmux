public import CmuxNextCloud
public import CmuxNextDaemon
public import Foundation
import os

/// Carries the person's signed Cloud capability (cmux-platform#1126) on the credential relay's calls, so a
/// create or a start skips the plan and membership reads the capability already passed (Leo, 2026-11-09: "can't
/// we just pre-approve peopel sometimes? the handshakes themsleves take ms, no?"). Every rule (which token a call
/// sends, when to ask for the next, what an answer keeps) is Rust's (cmux-cloud-start-core `capability`, ops
/// `cloud_capability_use` and `cloud_capability_keep`); this actor only keeps Rust's state and does the fetch.
/// A call never waits for a fetch: it goes with the token held, or with none (the server's full checks).
public actor CloudCapabilityHolder {
    public typealias Fetch = @Sendable (_ installToken: String) async -> (status: Int, body: Data)

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud")
    private var state: JSONValue = .object([:])
    private let fetch: Fetch
    private let now: @Sendable () -> UInt64

    public init(fetch: @escaping Fetch, now: @escaping @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970 * 1000) }) {
        self.fetch = fetch
        self.now = now
    }

    /// The live fetch: `POST /v1/cloud/capability` on the platform origin with the install token, so the token is
    /// minted for the same principal (this install) the relay's calls carry.
    public static func live(platform: URL, headers: [String: String]) -> CloudCapabilityHolder {
        let transport = InstallHTTPTransport(baseURL: platform)
        return CloudCapabilityHolder { token in
            (try? await transport.post("v1/cloud/capability", json: Data("{}".utf8), bearer: token, headers: headers)) ?? (0, Data())
        }
    }

    /// The headers for one call made with `installToken`; starts the next fetch in the background when Rust says so.
    public func headers(installToken: String) -> [String: String] {
        let team = MacInstallIdentity.team(ofToken: installToken)
        struct Reply: Decodable { var header: String?; var fetch: Bool; var state: JSONValue }
        let request: JSONValue = .object(["state": state, "team": team.map(JSONValue.string) ?? .null, "nowMs": .number(Double(now()))])
        guard let reply = CloudStartCore().call("cloud_capability_use", request, as: Reply.self) else { return [:] }
        state = reply.state
        if reply.fetch, let team { start(team: team, installToken: installToken) }
        return reply.header.map { ["x-cmux-cloud-capability": $0] } ?? [:]
    }

    /// Asks for a token now (sign-in, a team switch, the person typing in a Cloud composer), unless Rust says one
    /// is held and fresh or a fetch is in flight. Signed out (no install token), nothing.
    public func prefetch(_ identity: MacInstallIdentity) async {
        guard let token = try? await identity.installToken() else { return }
        _ = headers(installToken: token)
    }

    /// The install token was refused or the account changed: no token is sent until a new one is fetched.
    public func drop() { state = .object([:]) }

    private func start(team: String, installToken: String) {
        let sent = now()
        // task-owner: fire and forget; bounded by the transport's own timeout, and its answer only updates `state`.
        Task { [fetch] in
            let answer = await fetch(installToken)
            await self.keep(team: team, sent: sent, status: answer.status, body: answer.body)
        }
    }

    private func keep(team: String, sent: UInt64, status: Int, body: Data) {
        struct Reply: Decodable { var state: JSONValue; var outcome: String }
        let parsed = (try? JSONDecoder().decode(JSONValue.self, from: body)) ?? .null
        let request: JSONValue = .object(["state": state, "team": .string(team), "sentMs": .number(Double(sent)),
                                          "nowMs": .number(Double(now())), "status": .number(Double(status)), "body": parsed])
        guard let reply = CloudStartCore().call("cloud_capability_keep", request, as: Reply.self) else { return }
        state = reply.state
        Self.logger.info("cloud capability: \(reply.outcome, privacy: .public)")
    }
}

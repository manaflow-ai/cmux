public import CmuxNextCloud
public import CmuxNextDaemon
public import Foundation
import os

public nonisolated extension CloudCredentialRelay {
    /// One install-bound relay shared by the app provider and private link carrier.
    static func live(identity: MacInstallIdentity, baseURL: URL, capability: CloudPreApproval? = nil,
                     signedIn: @escaping @Sendable () async -> Bool,
                     allowedOps: @escaping @Sendable () async -> Set<String>,
                     carrierSocket: @escaping CarrierSocket = CloudCredentialRelay.noCarrier) -> CloudCredentialRelay {
        let transport = InstallHTTPTransport(baseURL: baseURL)
        let headers = identity.requestHeaders
        return CloudCredentialRelay(
            // The person's pre-approval rides on every call (cmux-platform#1126); none held, the server checks in full.
            post: { path, body, bearer in
                let approved = capability?.headers(installToken: bearer) ?? [:]
                return try await transport.post(path, json: body, bearer: bearer, headers: headers.merging(approved) { $1 })
            },
            token: { try await identity.installToken() },
            invalidate: { capability?.drop(); await identity.invalidate() },
            session: {
                guard await signedIn() else { return Session(signedIn: false, team: nil) }
                // Bill the install token's backend team, never the Stack team ID.
                let token = try? await identity.installToken()
                return Session(signedIn: true, team: token.flatMap(MacInstallIdentity.team(ofToken:)))
            },
            allowedOps: allowedOps,
            carrierSocket: carrierSocket)
    }
}

/// The person's signed Cloud pre-approval (cmux-platform#1126) on the relay's calls (Leo, 2026-11-09: "can't we just
/// pre-approve peopel sometimes? the handshakes themsleves take ms, no?"). Rust holds the token for this process and
/// makes every decision (cmux-cloud-start-core `capability`, ops `cloud_capability_header`, `_answer`, `_drop`); this
/// only makes the fetch Rust asks for. A call never waits on it: it goes with the token held, or with none.
public struct CloudPreApproval: Sendable {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud")
    private let platform: URL
    private let headers: [String: String]

    /// `platform`: the origin that serves `POST /v1/cloud/capability`; `headers`: the install's request headers.
    public init(platform: URL, headers: [String: String]) {
        self.platform = platform
        self.headers = headers
    }

    /// The header for one call made with `installToken`; starts the fetch in the background when Rust says so.
    public func headers(installToken: String) -> [String: String] {
        struct Reply: Decodable { var header: String?; var fetch: Bool }
        let team = MacInstallIdentity.team(ofToken: installToken)
        let request: JSONValue = .object(["team": team.map(JSONValue.string) ?? .null, "nowMs": .number(Self.nowMs())])
        guard let reply = CloudStartCore().call("cloud_capability_header", request, as: Reply.self) else { return [:] }
        if reply.fetch, let team { fetch(team: team, installToken: installToken) }
        return reply.header.map { ["x-cmux-cloud-capability": $0] } ?? [:]
    }

    /// Asks for a token now (sign-in, the person typing in a Cloud composer) unless one is held or in flight.
    public func prefetch(_ identity: MacInstallIdentity) async {
        guard let token = try? await identity.installToken() else { return }
        _ = headers(installToken: token)
    }

    /// The account or team changed, or the install token was refused: nothing is sent until a new token arrives.
    public func drop() { _ = CloudStartCore().call("cloud_capability_drop", JSONValue.object([:]), as: JSONValue.self) }

    private func fetch(team: String, installToken: String) {
        let sent = Self.nowMs()
        let transport = InstallHTTPTransport(baseURL: platform)
        // task-owner: fire and forget; bounded by the transport's own timeout, and its answer only reaches Rust.
        Task { [headers] in
            let answer: (status: Int, body: Data) = (try? await transport.post("v1/cloud/capability", json: Data("{}".utf8), bearer: installToken, headers: headers)) ?? (status: 0, body: Data())
            struct Reply: Decodable { var outcome: String }
            let body = (try? JSONDecoder().decode(JSONValue.self, from: answer.body)) ?? .null
            let request: JSONValue = .object(["team": .string(team), "sentMs": .number(sent), "nowMs": .number(Self.nowMs()),
                                              "status": .number(Double(answer.status)), "body": body])
            let outcome = CloudStartCore().call("cloud_capability_answer", request, as: Reply.self)?.outcome ?? "unread"
            Self.logger.info("cloud capability: \(outcome, privacy: .public)")
        }
    }

    private static func nowMs() -> Double { (Date().timeIntervalSince1970 * 1000).rounded(.down) }
}

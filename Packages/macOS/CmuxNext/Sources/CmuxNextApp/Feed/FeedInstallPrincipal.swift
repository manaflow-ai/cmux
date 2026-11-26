import CmuxNextCloud
import CmuxNextFeedClient
import Foundation
import Observation

/// This Mac's install principal for the feed handoff (plans/cmux-next/
/// feed.md 9.1 rule 4): FeedDO takes `feed.adopt` only from an install, so the
/// handoff driver calls the owner with the install token, never the Stack
/// bearer. `installID` is the token's `inst` claim; it is known once a token
/// was minted (at sign-in, `refresh()`), and observable so the driver turns
/// on when it arrives.
@MainActor
@Observable
final class FeedInstallPrincipal {
    private(set) var installID: String?
    @ObservationIgnored private let identity: MacInstallIdentity
    @ObservationIgnored private let baseURL: URL
    /// The bundled cmux that runs the owner calls (``CloudAuth/machineIO``); nil: they answer "cmux is not available".
    @ObservationIgnored private let machineIO: () -> CloudMachineIO?
    /// The Cloud configuration: its ``CloudConfiguration/buildSpace`` (a misconfigured dev build sends nothing).
    @ObservationIgnored private let configuration: CloudConfiguration
    @ObservationIgnored private var refreshing: Task<Void, Never>?

    init(identity: MacInstallIdentity, baseURL: URL, configuration: CloudConfiguration,
         machineIO: @escaping () -> CloudMachineIO?) {
        self.identity = identity
        self.baseURL = baseURL
        self.machineIO = machineIO
        self.configuration = configuration
    }

    /// Mints (or reuses) an install token and records its install id; a
    /// failure (signed out, no network) leaves the id unknown.
    func refresh() {
        guard refreshing == nil else { return }
        // task-owner: FeedInstallPrincipal.refreshing: one token mint; it clears itself when it settles.
        refreshing = Task { [weak self, identity] in
            let token = try? await identity.installToken()
            guard let self else { return }
            installID = token.flatMap(Self.install(ofToken:))
            refreshing = nil
        }
    }

    /// This Mac's install id, minting an install token when it is not known yet (the first
    /// prompt can come before the sign-in's refresh settles); nil while signed out.
    func ensureInstallID() async -> String? {
        if let installID { return installID }
        guard let token = try? await identity.installToken() else { return nil }
        if let install = Self.install(ofToken: token) { installID = install }
        return installID
    }

    /// POSTs `body` to `path` (`v1/ops` or `v1/read`) as this install and
    /// returns the owner's reply; an owner error is `FeedServiceError.owner`. The daemon's
    /// `cloud.owner.op` (``FeedOwnerCall``) sends it, so the install token never goes through Swift
    /// HTTP; a 401 drops the token so the next call mints a new one.
    func call(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard let route = FeedOwnerCall.Route(path: path) else { throw FeedServiceError.badReply }
        let token = try await identity.installToken()
        if let install = Self.install(ofToken: token) { installID = install }
        let reply = try await FeedOwnerCall(baseURL: baseURL, credential: { token }, configuration: configuration, machineIO: machineIO(),
                                            clientVersion: identity.requestHeaders["x-cmux-client-version"]).send(route, body)
        if reply.status == 401 { await identity.invalidate() }
        return try FeedOwnerCall.read(reply)
    }

    /// This Mac's context (environment, user, install from its token) and the
    /// owner's presence keys (`user.presence_key.list`, owner Mac installs
    /// only), for the agent permission bridge's allow check (cx-aocz).
    func presenceKeys() async throws
        -> (context: FeedApproveProofCheck.Context, keys: [String: FeedApproveProofCheck.Key]) {
        let token = try await identity.installToken()
        guard let context = FeedApproveProofCheck.context(ofToken: token) else { throw FeedServiceError.badReply }
        let reply = try await call("v1/read", ["op": "user.presence_key.list", "params": [String: Any]()])
        guard let value = reply["value"] as? [String: Any] else { throw FeedServiceError.badReply }
        return (context, FeedApproveProofCheck.keys(from: value))
    }

    /// The `inst` claim of an install token (the owner's install id).
    nonisolated static func install(ofToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let install = claims["inst"] as? String, !install.isEmpty else { return nil }
        return install
    }
}

public import CmuxControlPlane
import CmuxMobileWire
public import Foundation

/// The pairing ops on the account's `/v1/wire/user` socket (b6-pairing.md
/// section 6). Each call is one intent with one idempotency key; the trust
/// store changes arrive on `TrustStoreMirror`, never from these answers.
public struct PairingClient: Sendable {
    private let client: ControlPlaneClient

    public init(client: ControlPlaneClient) { self.client = client }

    /// Publishes this install's link cert (`host` for a Mac that enrolled it).
    public func publish(_ certificate: LinkCertificate, host: String? = nil, key: String = UUID().uuidString) async throws {
        var params: [String: JSONValue] = ["cert": try JSONValue(encoding: certificate)]
        if let host { params["host"] = .string(host) }
        _ = try await submit("trust.key.publish", .object(params), key: key)
    }

    /// The Mac's QR offer for its host.
    public func offer(host: String, team: String, key: String = UUID().uuidString) async throws -> PairingOfferResult {
        try await submit("pairing.offer", .object(["host": .string(host), "team": .string(team)]), key: key)
            .decode(as: PairingOfferResult.self)
    }

    /// Claims a scanned offer, bound to the host key the QR code carried.
    public func claim(_ offer: PairingOffer, key: String = UUID().uuidString) async throws -> PairingClaimResult {
        let params: JSONValue = .object(["offer": .string(offer.code), "host": .string(offer.host), "host_key": .string(offer.hostKey)])
        return try await submit("pairing.claim", params, key: key).decode(as: PairingClaimResult.self)
    }

    public func accept(offerID: String, key: String = UUID().uuidString) async throws {
        _ = try await submit("trust.request.accept", .object(["offer_id": .string(offerID)]), key: key)
    }

    public func decline(offerID: String, key: String = UUID().uuidString) async throws {
        _ = try await submit("trust.request.decline", .object(["offer_id": .string(offerID)]), key: key)
    }

    /// Removes a guest from a host (owner) or this account's device from another account's host.
    public func revoke(host: String, install: String, key: String = UUID().uuidString) async throws {
        _ = try await submit("pairing.revoke", .object(["host": .string(host), "install": .string(install)]), key: key)
    }

    private func submit(_ op: String, _ params: JSONValue, key: String) async throws -> JSONValue {
        switch try await client.submit(OpFrame(op: op, params: params, idempotencyKey: key, origin: .user)) {
        case .applied(let result): return result.value
        case .rejected(let reject): throw PairingClientError(code: reject.code, message: reject.message, retryable: reject.retryable)
        }
    }
}

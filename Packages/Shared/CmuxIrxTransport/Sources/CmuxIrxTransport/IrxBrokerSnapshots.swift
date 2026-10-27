public import CmuxIrohTransport
public import Foundation

public enum IrxBrokerServiceError: Error, Sendable {
    case notRegistered
    case invalidIdentity
    case noCredentialsIssued
    case unknownRelayURL(String)
    case deactivated
}

/// Persisted registration receipt: the full binding tuple, so the host can
/// build its exact acceptor identity for grant verification with the backend
/// unreachable.
public struct IrxBindingSnapshot: Codable, Equatable, Sendable {
    public var bindingID: String
    public var deviceID: String
    public var tag: String
    public var endpointIDHex: String
    public var identityGeneration: Int
    public var registeredAt: Date

    public init(
        bindingID: String,
        deviceID: String,
        tag: String,
        endpointIDHex: String,
        identityGeneration: Int,
        registeredAt: Date
    ) {
        self.bindingID = bindingID
        self.deviceID = deviceID
        self.tag = tag
        self.endpointIDHex = endpointIDHex
        self.identityGeneration = identityGeneration
        self.registeredAt = registeredAt
    }
}

/// Persisted grant-verification material and peer directory from the last
/// authenticated discovery. Admission verifies OFFLINE against this; a stale
/// copy is refreshed opportunistically in the background, never on the
/// admission or dial path.
public struct IrxTrustSnapshot: Codable, Equatable, Sendable {
    public var verificationKeys: CmxIrohGrantVerificationKeySet
    public var relayFleet: [String]
    public var fetchedAt: Date

    public init(
        verificationKeys: CmxIrohGrantVerificationKeySet,
        relayFleet: [String],
        fetchedAt: Date
    ) {
        self.verificationKeys = verificationKeys
        self.relayFleet = relayFleet
        self.fetchedAt = fetchedAt
    }
}

/// Persisted pair grant for one acceptor binding.
public struct IrxGrantSnapshot: Codable, Equatable, Sendable {
    public var acceptorBindingID: String
    public var grantJWS: String
    public var expiresAt: Date

    public init(acceptorBindingID: String, grantJWS: String, expiresAt: Date) {
        self.acceptorBindingID = acceptorBindingID
        self.grantJWS = grantJWS
        self.expiresAt = expiresAt
    }

    /// Grants live 7 days; treat the last 24h as stale so renewal always has
    /// days of margin and can never cause a connect-time flurry.
    public func isFresh(at now: Date) -> Bool {
        expiresAt.timeIntervalSince(now) > 24 * 3600
    }
}

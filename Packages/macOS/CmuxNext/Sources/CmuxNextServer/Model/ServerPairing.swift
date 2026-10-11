public import Foundation

/// The server's side of pairing (server.md section 6.2).
public nonisolated enum ServerPairingState: Sendable, Equatable {
    /// Not paired and no code requested yet.
    case unpaired(PairingOffer?)
    /// A device approved the code; the server is storing its credentials.
    case pairing
    case paired(ServerPairing)

    public var offer: PairingOffer? {
        if case let .unpaired(offer) = self { return offer }
        return nil
    }

    public var isPaired: Bool {
        if case .paired = self { return true }
        return false
    }
}

/// A live pairing code with its proof material: the four fingerprint words
/// and the QR payload that binds the install key's fingerprint.
public nonisolated struct PairingOffer: Sendable, Equatable {
    /// Eight Crockford base32 symbols without the dash.
    public var code: String
    public var expiresAt: Date
    public var words: [String]
    /// First 16 Crockford base32 symbols of SHA-256(install public key).
    public var fingerprint: String

    public init(code: String, expiresAt: Date, words: [String], fingerprint: String) {
        self.code = code
        self.expiresAt = expiresAt
        self.words = words
        self.fingerprint = fingerprint
    }

    public var displayCode: String { PairingCode.display(code) }
    public var qrPayload: String { PairingCode.payload(code: code, fingerprint: fingerprint) }
}

public nonisolated struct ServerPairing: Sendable, Equatable {
    public var team: String
    public var owner: String
    public var hostID: String

    public init(team: String, owner: String, hostID: String) {
        self.team = team
        self.owner = owner
        self.hostID = hostID
    }
}

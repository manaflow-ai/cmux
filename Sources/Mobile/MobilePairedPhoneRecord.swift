import Foundation

/// The iOS application identity learned from one completed Mac pairing.
struct MobilePairedPhoneRecord: Codable, Equatable, Sendable {
    /// How this record became known to the Mac.
    enum Source: String, Codable, Sendable {
        case authenticatedHandshake
        case legacyPickerMigration
    }

    let clientID: String
    let bundleIdentifier: String
    let accountID: String?
    let pairedAt: Date
    let source: Source
    /// A stable proof boundary for the authenticated transport that observed
    /// this install. It is intentionally not a bearer token.
    let handshakeIdentity: String?

    init(
        clientID: String,
        bundleIdentifier: String,
        accountID: String?,
        pairedAt: Date,
        source: Source = .authenticatedHandshake,
        handshakeIdentity: String? = nil
    ) {
        self.clientID = clientID
        self.bundleIdentifier = bundleIdentifier
        self.accountID = accountID
        self.pairedAt = pairedAt
        self.source = source
        self.handshakeIdentity = handshakeIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case clientID
        case bundleIdentifier
        case accountID
        case pairedAt
        case source
        case handshakeIdentity
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            clientID: try container.decode(String.self, forKey: .clientID),
            bundleIdentifier: try container.decode(String.self, forKey: .bundleIdentifier),
            accountID: try container.decodeIfPresent(String.self, forKey: .accountID),
            pairedAt: try container.decode(Date.self, forKey: .pairedAt),
            source: try container.decodeIfPresent(Source.self, forKey: .source)
                ?? .authenticatedHandshake,
            handshakeIdentity: try container.decodeIfPresent(
                String.self,
                forKey: .handshakeIdentity
            )
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clientID, forKey: .clientID)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encodeIfPresent(accountID, forKey: .accountID)
        try container.encode(pairedAt, forKey: .pairedAt)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(handshakeIdentity, forKey: .handshakeIdentity)
    }
}

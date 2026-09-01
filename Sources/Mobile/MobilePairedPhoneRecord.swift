import Foundation

/// The iOS application identity learned from one completed Mac pairing.
struct MobilePairedPhoneRecord: Codable, Equatable, Sendable {
    let clientID: String
    let bundleIdentifier: String
    let accountID: String?
    let pairedAt: Date
    let source: MobilePairedPhoneRecordSource
    /// The authenticated iOS development tag when this phone reached the Mac
    /// through an explicit cross-tag Iroh grant. `nil` means the exact Mac lane
    /// or an official release namespace was used.
    let trustedIOSBuildTag: String?
    /// A stable proof boundary for the authenticated transport that observed
    /// this install. It is intentionally not a bearer token.
    let handshakeIdentity: String?

    init(
        clientID: String,
        bundleIdentifier: String,
        accountID: String?,
        pairedAt: Date,
        source: MobilePairedPhoneRecordSource = .authenticatedHandshake,
        trustedIOSBuildTag: String? = nil,
        handshakeIdentity: String? = nil
    ) {
        self.clientID = clientID
        self.bundleIdentifier = bundleIdentifier
        self.accountID = accountID
        self.pairedAt = pairedAt
        self.source = source
        self.trustedIOSBuildTag = trustedIOSBuildTag
        self.handshakeIdentity = handshakeIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case clientID
        case bundleIdentifier
        case accountID
        case pairedAt
        case source
        case trustedIOSBuildTag
        case handshakeIdentity
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            clientID: try container.decode(String.self, forKey: .clientID),
            bundleIdentifier: try container.decode(String.self, forKey: .bundleIdentifier),
            accountID: try container.decodeIfPresent(String.self, forKey: .accountID),
            pairedAt: try container.decode(Date.self, forKey: .pairedAt),
            source: try container.decodeIfPresent(
                MobilePairedPhoneRecordSource.self,
                forKey: .source
            )
                ?? .authenticatedHandshake,
            trustedIOSBuildTag: try container.decodeIfPresent(
                String.self,
                forKey: .trustedIOSBuildTag
            ),
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
        try container.encodeIfPresent(trustedIOSBuildTag, forKey: .trustedIOSBuildTag)
        try container.encodeIfPresent(handshakeIdentity, forKey: .handshakeIdentity)
    }
}

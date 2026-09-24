public import Foundation

/// Wire descriptor for the peer key used by HPKE envelope version 2.
/// installationID is independent from the mobile RPC client_id.
public struct MobilePhonePushPublicKeyDescriptor: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let algorithm = "rawX25519"

    public let version: Int
    public let algorithm: String
    public let installationID: String
    public let keyID: String
    public let publicKey: Data

    public init(
        version: Int = Self.currentVersion,
        algorithm: String = Self.algorithm,
        installationID: String,
        keyID: String,
        publicKey: Data
    ) {
        self.version = version
        self.algorithm = algorithm
        self.installationID = installationID
        self.keyID = keyID
        self.publicKey = publicKey
    }

    public func validate() throws {
        guard version == Self.currentVersion,
              algorithm == Self.algorithm,
              !installationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !keyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              publicKey.count == 32 else {
            throw MobilePhonePushKeyExchangeError.invalidDescriptor
        }
    }
}

public struct MobilePhonePushKeyExchangeRequest: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let hpkeEnvelopeVersion = 2

    public let version: Int
    public let hpkeEnvelopeVersion: Int
    public let clientID: String
    public let iosBuildID: String
    public let descriptor: MobilePhonePushPublicKeyDescriptor

    public init(
        clientID: String,
        iosBuildID: String,
        descriptor: MobilePhonePushPublicKeyDescriptor
    ) {
        version = Self.currentVersion
        hpkeEnvelopeVersion = Self.hpkeEnvelopeVersion
        self.clientID = clientID
        self.iosBuildID = iosBuildID
        self.descriptor = descriptor
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case hpkeEnvelopeVersion = "hpke_envelope_version"
        case clientID = "client_id"
        case iosBuildID = "ios_build_id"
        case descriptor
    }

    public func validate() throws {
        guard version == Self.currentVersion,
              hpkeEnvelopeVersion == Self.hpkeEnvelopeVersion,
              !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !iosBuildID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MobilePhonePushKeyExchangeError.invalidRequest
        }
        try descriptor.validate()
    }
}

public struct MobilePhonePushKeyExchangeResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let hpkeEnvelopeVersion: Int
    public let descriptor: MobilePhonePushPublicKeyDescriptor
    public let accountID: String
    public let teamID: String?
    public let macDeviceID: String
    public let macInstanceTag: String
    public let macBuildID: String

    public init(
        descriptor: MobilePhonePushPublicKeyDescriptor,
        accountID: String,
        teamID: String? = nil,
        macDeviceID: String,
        macInstanceTag: String,
        macBuildID: String
    ) {
        version = MobilePhonePushKeyExchangeRequest.currentVersion
        hpkeEnvelopeVersion = MobilePhonePushKeyExchangeRequest.hpkeEnvelopeVersion
        self.descriptor = descriptor
        self.accountID = accountID
        self.teamID = teamID
        self.macDeviceID = macDeviceID
        self.macInstanceTag = macInstanceTag
        self.macBuildID = macBuildID
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case hpkeEnvelopeVersion = "hpke_envelope_version"
        case descriptor
        case accountID = "account_id"
        case teamID = "team_id"
        case macDeviceID = "mac_device_id"
        case macInstanceTag = "mac_instance_tag"
        case macBuildID = "mac_build_id"
    }

    /// Whether this reply came from the Mac build that advertised
    /// `clientNamespace` as `mac_client_namespace` in its host status.
    ///
    /// The status field is the Iroh broker form `mac:<lowercased bundle id>`
    /// (`CmxIrohMacBundleNamespace`), while `macBuildID` is the raw bundle id
    /// that push tuples carry. Comparing them directly never matches, so the
    /// phone rejected every exchange and never pinned the Mac's key.
    public func matchesMacClientNamespace(_ clientNamespace: String) -> Bool {
        clientNamespace == "mac:" + macBuildID.lowercased()
    }

    public func validate() throws {
        guard version == MobilePhonePushKeyExchangeRequest.currentVersion,
              hpkeEnvelopeVersion == MobilePhonePushKeyExchangeRequest.hpkeEnvelopeVersion,
              !accountID.isEmpty,
              !macDeviceID.isEmpty,
              !macInstanceTag.isEmpty,
              !macBuildID.isEmpty else {
            throw MobilePhonePushKeyExchangeError.invalidResponse
        }
        try descriptor.validate()
    }
}

public enum MobilePhonePushKeyExchangeError: Error, Equatable, Sendable {
    case invalidDescriptor
    case invalidRequest
    case invalidResponse
}

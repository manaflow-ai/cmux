public import Foundation

/// Saved connection settings with references to separately stored secrets.
///
/// Addresses and usernames are private vault data when synchronized.
public struct MobileRemoteProfile: Codable, Equatable, Identifiable, Sendable {
    /// Stable profile identifier, independent of its address.
    public let id: UUID
    /// Optional display name.
    public let name: String?
    /// DNS name or bare IP address, without URL syntax.
    public let host: String
    /// SSH port in 1 through 65535.
    public let port: Int
    /// Remote account name.
    public let username: String
    /// Selected connection protocol; automatic selection must honor required capabilities.
    public let carrier: MobileRemoteCarrier
    /// Requested authentication policy; challenge responses are never saved here.
    public let authentication: MobileRemoteAuthentication
    /// Remote session type; cmux uses its native protocol.
    public let sessionBackend: MobileRemoteSessionBackend
    /// Optional multiplexer session selector.
    public let sessionName: String?
    /// Optional starting directory on the remote host.
    public let workingDirectory: String?
    /// Separate SSH profile for a jump host; graph cycles are checked by the resolver.
    public let jumpHostProfileID: UUID?
    /// User confirmation or pre-established trust required before authentication.
    public let hostKeyPolicy: MobileRemoteHostKeyPolicy
    /// Reference to a credential store item, never the credential itself.
    public let credentialID: UUID?
    /// Whether to expose explicitly allowed signing identities to this SSH session.
    public let agentForwarding: Bool
    /// Optional remote path used to bootstrap Mosh.
    public let moshServerPath: String?
    /// Optional permitted UDP port interval for Mosh.
    public let moshUDPPortRange: ClosedRange<Int>?
    /// Optional Eternal Terminal TCP port, defaulting to 2022 at connection time.
    public let eternalTerminalPort: Int?
    /// Remote environment values; always transfer as data, never concatenate into shell code.
    public let environment: [String: String]
    /// Whether to request CMUX_CLIENT=1 on the remote host.
    public let sendClientEnvironmentFlag: Bool
    /// Original profile creation time.
    public let createdAt: Date
    /// Last explicit profile edit time, not a trust or authorization version.
    public let updatedAt: Date

    /// Creates validated connection settings without accessing credentials.
    ///
    /// - Parameters:
    ///   - id: Stable profile identifier, independent of its address.
    ///   - name: Optional display name.
    ///   - host: DNS name or bare IP address, without URL syntax.
    ///   - port: SSH port in 1 through 65535.
    ///   - username: Remote account name.
    ///   - carrier: Selected connection protocol; automatic selection must honor required capabilities.
    ///   - authentication: Requested authentication policy; challenge responses are never saved here.
    ///   - sessionBackend: Remote session type; cmux uses its native protocol.
    ///   - sessionName: Optional multiplexer session selector.
    ///   - workingDirectory: Optional starting directory on the remote host.
    ///   - jumpHostProfileID: Separate SSH profile for a jump host; graph cycles are checked by the resolver.
    ///   - hostKeyPolicy: User confirmation or pre-established trust required before authentication.
    ///   - credentialID: Reference to a credential store item, never the credential itself.
    ///   - agentForwarding: Whether to expose explicitly allowed signing identities to this SSH session.
    ///   - moshServerPath: Optional remote path used to bootstrap Mosh.
    ///   - moshUDPPortRange: Optional permitted UDP port interval for Mosh.
    ///   - eternalTerminalPort: Optional Eternal Terminal TCP port, defaulting to 2022 at connection time.
    ///   - environment: Remote environment values; always transfer as data, never concatenate into shell code.
    ///   - sendClientEnvironmentFlag: Whether to request CMUX_CLIENT=1 on the remote host.
    ///   - createdAt: Original profile creation time.
    ///   - updatedAt: Last explicit profile edit time, not a trust or authorization version.
    /// - Throws: A profile validation error.
    public init(
        id: UUID,
        name: String? = nil,
        host: String,
        port: Int = 22,
        username: String,
        carrier: MobileRemoteCarrier = .automatic,
        authentication: MobileRemoteAuthentication = .publicKey,
        sessionBackend: MobileRemoteSessionBackend = .shell,
        sessionName: String? = nil,
        workingDirectory: String? = nil,
        jumpHostProfileID: UUID? = nil,
        hostKeyPolicy: MobileRemoteHostKeyPolicy = .ask,
        credentialID: UUID? = nil,
        agentForwarding: Bool = false,
        moshServerPath: String? = nil,
        moshUDPPortRange: ClosedRange<Int>? = nil,
        eternalTerminalPort: Int? = nil,
        environment: [String: String] = [:],
        sendClientEnvironmentFlag: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) throws {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.carrier = carrier
        self.authentication = authentication
        self.sessionBackend = sessionBackend
        self.sessionName = sessionName
        self.workingDirectory = workingDirectory
        self.jumpHostProfileID = jumpHostProfileID
        self.hostKeyPolicy = hostKeyPolicy
        self.credentialID = credentialID
        self.agentForwarding = agentForwarding
        self.moshServerPath = moshServerPath
        self.moshUDPPortRange = moshUDPPortRange
        self.eternalTerminalPort = eternalTerminalPort
        self.environment = environment
        self.sendClientEnvironmentFlag = sendClientEnvironmentFlag
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, carrier, authentication
        case sessionBackend, sessionName, workingDirectory, jumpHostProfileID
        case hostKeyPolicy, credentialID, agentForwarding, moshServerPath
        case moshUDPPortRange, eternalTerminalPort, environment, sendClientEnvironmentFlag
        case createdAt, updatedAt
    }

    /// Decodes a saved profile with the same checks as user-created values.
    ///
    /// - Parameter decoder: Decoder of the profile record.
    /// - Throws: Decoding or validation errors.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(UUID.self, forKey: .id),
            name: values.decodeIfPresent(String.self, forKey: .name),
            host: values.decode(String.self, forKey: .host),
            port: values.decode(Int.self, forKey: .port),
            username: values.decode(String.self, forKey: .username),
            carrier: values.decode(MobileRemoteCarrier.self, forKey: .carrier),
            authentication: values.decode(MobileRemoteAuthentication.self, forKey: .authentication),
            sessionBackend: values.decode(MobileRemoteSessionBackend.self, forKey: .sessionBackend),
            sessionName: values.decodeIfPresent(String.self, forKey: .sessionName),
            workingDirectory: values.decodeIfPresent(String.self, forKey: .workingDirectory),
            jumpHostProfileID: values.decodeIfPresent(UUID.self, forKey: .jumpHostProfileID),
            hostKeyPolicy: values.decode(MobileRemoteHostKeyPolicy.self, forKey: .hostKeyPolicy),
            credentialID: values.decodeIfPresent(UUID.self, forKey: .credentialID),
            agentForwarding: values.decode(Bool.self, forKey: .agentForwarding),
            moshServerPath: values.decodeIfPresent(String.self, forKey: .moshServerPath),
            moshUDPPortRange: values.decodeIfPresent(ClosedRange<Int>.self, forKey: .moshUDPPortRange),
            eternalTerminalPort: values.decodeIfPresent(Int.self, forKey: .eternalTerminalPort),
            environment: values.decode([String: String].self, forKey: .environment),
            sendClientEnvironmentFlag: values.decode(Bool.self, forKey: .sendClientEnvironmentFlag),
            createdAt: values.decode(Date.self, forKey: .createdAt),
            updatedAt: values.decode(Date.self, forKey: .updatedAt)
        )
    }

    /// Checks settings before use, with no network or credential access.
    ///
    /// - Throws: A profile validation error.
    public func validate() throws {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MobileRemoteProfileError.emptyHost
        }
        guard !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              !host.contains(where: { "/\\@?#[]".contains($0) }) else {
            throw MobileRemoteProfileError.invalidHost
        }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MobileRemoteProfileError.invalidUsername
        }
        guard (1...65_535).contains(port) else {
            throw MobileRemoteProfileError.invalidPort(port)
        }
        if let range = moshUDPPortRange {
            guard (1...65_535).contains(range.lowerBound),
                  (1...65_535).contains(range.upperBound),
                  range.lowerBound <= range.upperBound else {
                throw MobileRemoteProfileError.invalidUDPRange
            }
        }
        if let eternalTerminalPort {
            guard (1...65_535).contains(eternalTerminalPort) else {
                throw MobileRemoteProfileError.invalidPort(eternalTerminalPort)
            }
        }
        if jumpHostProfileID == id {
            throw MobileRemoteProfileError.selfReferentialJumpHost
        }
        for (key, value) in environment {
            guard isValidEnvironmentKey(key) else {
                throw MobileRemoteProfileError.invalidEnvironmentKey
            }
            guard !value.contains("\0") else {
                throw MobileRemoteProfileError.invalidEnvironmentValue
            }
        }
    }

    private func isValidEnvironmentKey(_ key: String) -> Bool {
        guard let first = key.utf8.first, first == 95 || (65...90).contains(first) || (97...122).contains(first) else { return false }
        return key.utf8.allSatisfy { byte in
            byte == 95 || (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
        }
    }
}

import Foundation

/// What `ServerInit` (RFC 6143 section 7.3.2) and the handshake established.
public struct VNCServerInfo: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var name: String
    /// The server's native format (the client then asks for `RFBPixelFormat.bgrx`).
    public var nativeFormat: RFBPixelFormat
    /// The negotiated protocol minor version: 3, 7 or 8.
    public var protocolMinor: Int
    /// The security type used (1 none, 2 VNC password, 30 Apple DH).
    public var securityType: UInt8

    public init(width: Int, height: Int, name: String, nativeFormat: RFBPixelFormat, protocolMinor: Int, securityType: UInt8) {
        self.width = width
        self.height = height
        self.name = name
        self.nativeFormat = nativeFormat
        self.protocolMinor = protocolMinor
        self.securityType = securityType
    }
}

/// Security types this client implements.
enum RFBSecurityType {
    static let none: UInt8 = 1
    static let vncPassword: UInt8 = 2
    static let appleDH: UInt8 = 30
}

/// Version, security and initialisation (RFC 6143 sections 7.1 to 7.3). The choices and the
/// authentication answers are cmux-vnc's (``VNCRules``); this reads and writes the bytes.
struct RFBHandshake {
    var credentials: VNCCredentials
    var shared = true
    var rules: VNCRules

    func run(reader: RFBReader, transport: any RFBTransport) async throws -> VNCServerInfo {
        let banner = try await reader.bytes(12)
        guard rules.installed else { throw VNCRules.unavailable }
        guard let version = rules.version(banner: banner) else {
            throw RFBError.unsupportedProtocolVersion(String(decoding: banner, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let minor = version.minor
        try await transport.send(version.reply)

        let type = try await negotiateSecurity(reader: reader, transport: transport, minor: minor)
        switch type {
        case RFBSecurityType.vncPassword:
            guard let password = credentials.password else { throw RFBError.passwordRequired }
            let challenge = try await reader.bytes(16)
            guard let response = rules.passwordResponse(password: password, challenge: challenge) else {
                throw RFBError.authenticationFailed("could not compute the VNC response")
            }
            try await transport.send(response)
        case RFBSecurityType.appleDH:
            guard let username = credentials.username, let password = credentials.password else {
                throw RFBError.credentialsRequired
            }
            let generator = try await reader.u16()
            let length = Int(try await reader.u16())
            guard length > 0, length <= RFBLimits.maxDHKeyBytes else { throw RFBError.protocolViolation("Apple DH key length \(length)") }
            let prime = try await reader.bytes(length)
            let serverKey = try await reader.bytes(length)
            guard let response = rules.appleDH(generator: generator, prime: prime, serverPublicKey: serverKey,
                                               username: username, password: password) else {
                throw RFBError.authenticationFailed("could not compute the Apple DH response")
            }
            try await transport.send(response)
        default:
            break
        }
        // SecurityResult: always in 3.8; after real authentication in 3.3 and 3.7.
        if minor == 8 || type != RFBSecurityType.none {
            let result: UInt32
            do {
                result = try await reader.u32()
            } catch RFBError.connectionClosed where type != RFBSecurityType.none {
                // Some servers drop the connection instead of sending a failed result.
                throw RFBError.authenticationFailed("")
            }
            if result != 0 {
                let reason = minor == 8 ? (try? await reader.lengthPrefixedString(limit: 4096)) ?? "" : ""
                throw RFBError.authenticationFailed(reason)
            }
        }

        try await transport.send([shared ? 1 : 0])
        let width = Int(try await reader.u16())
        let height = Int(try await reader.u16())
        try RFBLimits.checkFramebuffer(width: width, height: height)
        let format = try await reader.bytes(16)
        let name = try await reader.lengthPrefixedString(limit: 4096)
        guard let nativeFormat = RFBPixelFormat(bytes: format) else { throw RFBError.protocolViolation("ServerInit format") }
        return VNCServerInfo(width: width, height: height, name: name, nativeFormat: nativeFormat,
                             protocolMinor: minor, securityType: type)
    }

    private func negotiateSecurity(reader: RFBReader, transport: any RFBTransport, minor: Int) async throws -> UInt8 {
        if minor == 3 {
            let word = try await reader.u32()
            if word == 0 { throw RFBError.authenticationFailed(try await reader.lengthPrefixedString(limit: 4096)) }
            return try rules.serverChosenSecurity(word: word, credentials: credentials)
        }
        let count = Int(try await reader.u8())
        if count == 0 { throw RFBError.authenticationFailed(try await reader.lengthPrefixedString(limit: 4096)) }
        let offered = try await reader.bytes(count)
        let chosen = try rules.chooseSecurity(offered: offered, credentials: credentials)
        try await transport.send([chosen])
        return chosen
    }
}

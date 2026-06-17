import Foundation

/// Result of `ServerInit` (RFC 6143 §7.3.2): the remote screen geometry, its
/// native pixel format, and its name.
public struct RFBServerInit: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixelFormat: RFBPixelFormat
    public var name: String

    public init(width: Int, height: Int, pixelFormat: RFBPixelFormat, name: String) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.name = name
    }
}

/// Drives the RFB version, security, and initialisation handshake. Pure with
/// respect to transport: it only reads from an ``RFBByteSource`` and writes to
/// an ``RFBByteSink``, so the whole negotiation is unit-testable end to end.
public struct RFBHandshake {
    public init() {}

    private static let none: UInt8 = 1
    private static let vncAuth: UInt8 = 2

    /// Negotiates and returns `ServerInit`. Throws ``RFBError`` on any failure.
    public func negotiate(
        source: any RFBByteSource,
        sink: any RFBByteSink,
        password: String?,
        shared: Bool = true
    ) async throws -> RFBServerInit {
        let serverMinor = try await readProtocolVersion(source)
        let agreedMinor = min(serverMinor, 8) >= 8 ? 8 : (serverMinor >= 7 ? 7 : 3)
        try await sink.write(Array("RFB 003.\(String(format: "%03d", agreedMinor))\n".utf8))

        let chosen = try await negotiateSecurity(
            source: source,
            sink: sink,
            agreedMinor: agreedMinor,
            password: password
        )

        if chosen == Self.vncAuth {
            try await performVNCAuth(source: source, sink: sink, password: password)
        }

        // SecurityResult: always for 3.8; for VNC auth on any version; never for
        // None on < 3.8.
        if agreedMinor >= 8 || chosen == Self.vncAuth {
            try await readSecurityResult(source, includeReason: agreedMinor >= 8)
        }

        try await sink.write([shared ? 1 : 0]) // ClientInit
        return try await readServerInit(source)
    }

    private func readProtocolVersion(_ source: any RFBByteSource) async throws -> Int {
        let bytes = try await source.readExactly(12)
        let text = String(decoding: bytes, as: UTF8.self)
        // Expected form "RFB 003.008\n".
        guard text.hasPrefix("RFB "), let dotIndex = text.firstIndex(of: ".") else {
            throw RFBError.unsupportedProtocolVersion(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let minorDigits = text[text.index(after: dotIndex)...].prefix { $0.isNumber }
        guard let minor = Int(minorDigits) else {
            throw RFBError.unsupportedProtocolVersion(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return minor
    }

    private func negotiateSecurity(
        source: any RFBByteSource,
        sink: any RFBByteSink,
        agreedMinor: Int,
        password: String?
    ) async throws -> UInt8 {
        let offered: [UInt8]
        if agreedMinor >= 7 {
            let count = try await source.readUInt8()
            guard count > 0 else {
                let reason = try await source.readLengthPrefixedString()
                throw RFBError.authenticationFailed(reason)
            }
            offered = try await source.readExactly(Int(count))
        } else {
            // 3.3: the server dictates a single security type as a U32.
            let type = try await source.readUInt32()
            guard type != 0 else {
                let reason = try await source.readLengthPrefixedString()
                throw RFBError.authenticationFailed(reason)
            }
            offered = [UInt8(truncatingIfNeeded: type)]
            // No client selection byte is sent in 3.3.
            try validateSelectable(offered, password: password)
            return offered.contains(Self.vncAuth) && password != nil ? Self.vncAuth : Self.none
        }

        let chosen = try preferredSecurity(from: offered, password: password)
        try await sink.write([chosen])
        return chosen
    }

    private func preferredSecurity(from offered: [UInt8], password: String?) throws -> UInt8 {
        // Prefer VNC auth when a password is available; otherwise None.
        if password != nil, offered.contains(Self.vncAuth) {
            return Self.vncAuth
        }
        if offered.contains(Self.none) {
            return Self.none
        }
        if offered.contains(Self.vncAuth) {
            // Server requires auth but we have no password.
            throw RFBError.passwordRequired
        }
        throw RFBError.noSupportedSecurityType(offered)
    }

    private func validateSelectable(_ offered: [UInt8], password: String?) throws {
        if offered.contains(Self.none) { return }
        if offered.contains(Self.vncAuth) {
            if password == nil { throw RFBError.passwordRequired }
            return
        }
        throw RFBError.noSupportedSecurityType(offered)
    }

    private func performVNCAuth(
        source: any RFBByteSource,
        sink: any RFBByteSink,
        password: String?
    ) async throws {
        guard let password else { throw RFBError.passwordRequired }
        let challenge = try await source.readExactly(16)
        let response = VNCAuthentication.challengeResponse(challenge: challenge, password: password)
        guard response.count == 16 else {
            throw RFBError.authenticationFailed("Failed to compute authentication response.")
        }
        try await sink.write(response)
    }

    private func readSecurityResult(_ source: any RFBByteSource, includeReason: Bool) async throws {
        let result = try await source.readUInt32()
        guard result == 0 else {
            let reason = includeReason ? (try? await source.readLengthPrefixedString()) ?? "" : ""
            throw RFBError.authenticationFailed(reason.isEmpty ? "Authentication failed." : reason)
        }
    }

    private func readServerInit(_ source: any RFBByteSource) async throws -> RFBServerInit {
        let width = try await source.readUInt16()
        let height = try await source.readUInt16()
        let formatBytes = try await source.readExactly(16)
        guard let format = RFBPixelFormat(formatBytes[...]) else {
            throw RFBError.protocolViolation("malformed ServerInit pixel format")
        }
        let name = try await source.readLengthPrefixedString()
        return RFBServerInit(width: Int(width), height: Int(height), pixelFormat: format, name: name)
    }
}

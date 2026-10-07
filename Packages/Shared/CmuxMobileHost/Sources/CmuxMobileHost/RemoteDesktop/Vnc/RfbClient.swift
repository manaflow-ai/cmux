import Foundation

/// An RFB 3.8 client (RFC 6143) for the Mac's VNC proxy (c3-rd.md 1):
/// versions 3.3, 3.7 and 3.8, security None and VNC authentication, 32-bit
/// BGRA true colour, Raw, CopyRect and DesktopSize. Never a server.
///
/// One task reads (`readMessage`); input and requests may be sent from any
/// task meanwhile (the actor serializes writes).
public actor RfbClient {
    public enum Version: String, Hashable, Sendable {
        case v3_3 = "RFB 003.003\n"
        case v3_7 = "RFB 003.007\n"
        case v3_8 = "RFB 003.008\n"
    }

    static let maxSide = 16_384
    static let maxText = 1 << 20

    private let transport: any RfbTransport
    public private(set) var version: Version = .v3_8
    private var width = 0
    private var height = 0

    public init(transport: any RfbTransport) {
        self.transport = transport
    }

    // MARK: Handshake

    /// Reads the server's ProtocolVersion and answers with the highest
    /// common one. Throws `notRfb` for any other peer.
    @discardableResult
    public func negotiateVersion() async throws -> Version {
        let banner = try await transport.read(exactly: 12)
        guard banner.starts(with: Data("RFB ".utf8)), banner.last == 0x0A,
              let text = String(data: banner, encoding: .ascii) else { throw RfbError.notRfb }
        let digits = text.dropFirst(4).dropLast()
        let parts = digits.split(separator: ".")
        guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { throw RfbError.notRfb }
        guard major == 3 else { throw RfbError.unsupportedVersion(String(digits)) }
        // 3.4 and 3.6 are 3.3 dialects; 3.889 (Apple) and later speak 3.8.
        version = switch minor {
        case ..<7: .v3_3
        case 7: .v3_7
        default: .v3_8
        }
        try await transport.write(Data(version.rawValue.utf8))
        return version
    }

    /// Picks None when offered, else VNC authentication with the password
    /// `password()` returns (asked only then). Throws `authUnsupported`,
    /// `passwordMissing`, `authFailed` or `refused`.
    public func authenticate(password: @Sendable () async -> String?) async throws {
        var chosen: UInt8
        switch version {
        case .v3_3:
            let type = try await u32()
            if type == 0 { throw RfbError.refused(try await reason()) }
            guard type == 1 || type == 2 else { throw RfbError.authUnsupported([UInt8(truncatingIfNeeded: type)]) }
            chosen = UInt8(type)
        case .v3_7, .v3_8:
            let count = Int(try await u8())
            if count == 0 { throw RfbError.refused(try await reason()) }
            let offered = [UInt8](try await transport.read(exactly: count))
            if offered.contains(1) {
                chosen = 1
            } else if offered.contains(2) {
                chosen = 2
            } else {
                throw RfbError.authUnsupported(offered)
            }
            try await transport.write(Data([chosen]))
        }
        if chosen == 2 {
            let challenge = try await transport.read(exactly: 16)
            guard let secret = await password() else { throw RfbError.passwordMissing }
            try await transport.write(try RfbVncAuth().response(challenge: challenge, password: secret))
        }
        // 3.8 always sends SecurityResult; 3.3 and 3.7 skip it for None.
        guard chosen == 2 || version == .v3_8 else { return }
        if try await u32() != 0 {
            throw RfbError.authFailed(version == .v3_8 ? try await reason() : "authentication failed")
        }
    }

    /// ClientInit (shared), ServerInit, then this client's pixel format and
    /// encodings and a first full update request.
    public func initialize() async throws -> RfbServerInit {
        try await transport.write(Data([1]))
        let width = Int(try await u16())
        let height = Int(try await u16())
        guard width <= Self.maxSide, height <= Self.maxSide else { throw RfbError.protocolError("framebuffer too large") }
        _ = try await transport.read(exactly: 16)
        let nameLength = Int(try await u32())
        guard nameLength <= Self.maxText else { throw RfbError.protocolError("name too long") }
        let name = String(decoding: try await transport.read(exactly: nameLength), as: UTF8.self)
        self.width = width
        self.height = height
        try await transport.write(Self.setPixelFormat)
        try await transport.write(Self.setEncodings)
        try await requestUpdate(incremental: false)
        return RfbServerInit(width: width, height: height, name: name)
    }

    // MARK: Client messages

    public func requestUpdate(incremental: Bool) async throws {
        var out = Data([3, incremental ? 1 : 0])
        out.appendBE(UInt16(0))
        out.appendBE(UInt16(0))
        out.appendBE(UInt16(clamping: width))
        out.appendBE(UInt16(clamping: height))
        try await transport.write(out)
    }

    public func key(_ keysym: UInt32, down: Bool) async throws {
        var out = Data([4, down ? 1 : 0, 0, 0])
        out.appendBE(keysym)
        try await transport.write(out)
    }

    /// `mask` bit n is button n + 1 (1 left, 2 middle, 3 right, 4 to 7 wheel).
    public func pointer(mask: UInt8, x: Int, y: Int) async throws {
        var out = Data([5, mask])
        out.appendBE(UInt16(clamping: max(0, min(x, max(0, width - 1)))))
        out.appendBE(UInt16(clamping: max(0, min(y, max(0, height - 1)))))
        try await transport.write(out)
    }

    /// ClientCutText. RFB text is Latin-1: other characters are dropped.
    public func cutText(_ text: String) async throws {
        let latin1 = Data(text.unicodeScalars.compactMap { $0.value <= 0xFF ? UInt8($0.value) : nil }.prefix(Self.maxText))
        var out = Data([6, 0, 0, 0])
        out.appendBE(UInt32(latin1.count))
        out.append(latin1)
        try await transport.write(out)
    }

    public func close() async {
        await transport.close()
    }

    // MARK: Server messages

    public func readMessage() async throws -> RfbServerMessage {
        switch try await u8() {
        case 0:
            _ = try await u8()
            let count = Int(try await u16())
            var rects: [RfbRect] = []
            rects.reserveCapacity(count)
            for _ in 0..<count { rects.append(try await readRect()) }
            return .update(rects)
        case 1:
            _ = try await u8()
            _ = try await u16()
            let colours = Int(try await u16())
            _ = try await transport.read(exactly: colours * 6)
            return .colourMap
        case 2:
            return .bell
        case 3:
            _ = try await transport.read(exactly: 3)
            let length = Int(try await u32())
            guard length <= Self.maxText else { throw RfbError.protocolError("cut text too long") }
            let bytes = try await transport.read(exactly: length)
            return .cutText(String(bytes.map { Character(Unicode.Scalar($0)) }))
        case let type:
            throw RfbError.protocolError("server message \(type)")
        }
    }

    private func readRect() async throws -> RfbRect {
        let x = Int(try await u16())
        let y = Int(try await u16())
        let w = Int(try await u16())
        let h = Int(try await u16())
        let encoding = Int32(bitPattern: try await u32())
        switch encoding {
        case 0:
            guard x + w <= width, y + h <= height else { throw RfbError.protocolError("raw rect outside the framebuffer") }
            return RfbRect(x: x, y: y, width: w, height: h, content: .raw(try await transport.read(exactly: w * h * 4)))
        case 1:
            let sx = Int(try await u16())
            let sy = Int(try await u16())
            return RfbRect(x: x, y: y, width: w, height: h, content: .copy(sourceX: sx, sourceY: sy))
        case -223:
            guard w <= Self.maxSide, h <= Self.maxSide else { throw RfbError.protocolError("framebuffer too large") }
            width = w
            height = h
            return RfbRect(x: x, y: y, width: w, height: h, content: .desktopSize)
        default:
            // Only negotiated encodings may arrive; anything else desyncs the stream.
            throw RfbError.protocolError("encoding \(encoding) was not negotiated")
        }
    }

    // MARK: Bytes

    private func u8() async throws -> UInt8 {
        try await transport.read(exactly: 1)[0]
    }

    private func u16() async throws -> UInt16 {
        let bytes = [UInt8](try await transport.read(exactly: 2))
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    private func u32() async throws -> UInt32 {
        let bytes = [UInt8](try await transport.read(exactly: 4))
        return bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func reason() async throws -> String {
        let length = Int(try await u32())
        guard length <= Self.maxText else { throw RfbError.protocolError("reason too long") }
        return String(decoding: try await transport.read(exactly: length), as: UTF8.self)
    }

    /// 32 bpp, depth 24, little-endian, true colour, 8 bits per channel,
    /// red at 16, green at 8, blue at 0: bytes B, G, R, X in memory.
    static let setPixelFormat = Data([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])

    /// CopyRect, Raw, DesktopSize.
    static let setEncodings: Data = {
        var out = Data([2, 0])
        let encodings: [Int32] = [1, 0, -223]
        out.appendBE(UInt16(encodings.count))
        for encoding in encodings { out.appendBE(UInt32(bitPattern: encoding)) }
        return out
    }()
}

extension Data {
    mutating func appendBE(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xff))
    }

    mutating func appendBE(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) { append(UInt8((value >> UInt32(shift)) & 0xff)) }
    }
}

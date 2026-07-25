public import Foundation

/// A canonical xterm-compatible terminal transport frame.
///
/// The fixed 56-byte header is followed by the UTF-8 workspace, pane, and
/// optional authoritative user identifiers, then opaque terminal bytes:
///
/// ```
/// CMXS | version | kind | flags | epoch | sequence start | sequence end
///      | rows | columns | workspace length | pane length | user length
///      | reserved | payload length | workspace | pane | user | payload
/// ```
///
/// All integer fields use network byte order. Terminal payloads are never
/// interpreted or transcoded by this codec.
public struct WorkspaceShareTerminalFrame: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        /// A synthesized VT stream that reconstructs authoritative terminal state.
        case baseline = 0x01

        /// Raw PTY output whose sequence range advances by its byte count.
        case output = 0x02

        /// Untrusted guest input. The relay must supply the authenticated user.
        case input = 0x03

        /// Guest input carrying the identity injected by the trusted relay.
        case forwardedInput = 0x04
    }

    public static let wireVersion = ShareProtocolConstants.terminalTransportVersion
    public static let headerByteCount = 56

    public let kind: Kind
    public let streamEpoch: UUID?
    public let sequenceStart: UInt64
    public let sequenceEnd: UInt64
    public let rows: UInt16
    public let columns: UInt16
    public let workspaceID: String
    public let paneID: String
    public let userID: String?
    public let bytes: Data

    public init(
        kind: Kind,
        streamEpoch: UUID?,
        sequenceStart: UInt64,
        sequenceEnd: UInt64,
        rows: UInt16,
        columns: UInt16,
        workspaceID: String,
        paneID: String,
        userID: String?,
        bytes: Data
    ) throws {
        try Self.validateIdentifier(workspaceID, field: .workspace)
        try Self.validateIdentifier(paneID, field: .pane)
        if let userID {
            try Self.validateIdentifier(userID, field: .user)
        }

        let workspaceByteCount = workspaceID.utf8.count
        let paneByteCount = paneID.utf8.count
        let userByteCount = userID?.utf8.count ?? 0
        try Self.validateFrameSize(
            workspaceByteCount: workspaceByteCount,
            paneByteCount: paneByteCount,
            userByteCount: userByteCount,
            payloadByteCount: bytes.count
        )
        try Self.validateSemantics(
            kind: kind,
            streamEpoch: streamEpoch,
            sequenceStart: sequenceStart,
            sequenceEnd: sequenceEnd,
            rows: rows,
            columns: columns,
            userID: userID,
            payloadByteCount: bytes.count
        )

        self.kind = kind
        self.streamEpoch = streamEpoch
        self.sequenceStart = sequenceStart
        self.sequenceEnd = sequenceEnd
        self.rows = rows
        self.columns = columns
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.userID = userID
        self.bytes = bytes
    }

    /// Encodes this validated frame without altering its opaque terminal bytes.
    public func encoded() throws -> Data {
        let workspaceBytes = Data(workspaceID.utf8)
        let paneBytes = Data(paneID.utf8)
        let userBytes = userID.map { Data($0.utf8) } ?? Data()

        try Self.validateFrameSize(
            workspaceByteCount: workspaceBytes.count,
            paneByteCount: paneBytes.count,
            userByteCount: userBytes.count,
            payloadByteCount: bytes.count
        )

        var encoded = Data(
            capacity: Self.headerByteCount
                + workspaceBytes.count
                + paneBytes.count
                + userBytes.count
                + bytes.count
        )
        encoded.append(contentsOf: Self.magic)
        encoded.append(Self.wireVersion)
        encoded.append(kind.rawValue)
        encoded.appendUInt16(0) // Flags are reserved for a future protocol version.
        encoded.append(contentsOf: Self.epochBytes(streamEpoch))
        encoded.appendUInt64(sequenceStart)
        encoded.appendUInt64(sequenceEnd)
        encoded.appendUInt16(rows)
        encoded.appendUInt16(columns)
        encoded.appendUInt16(UInt16(workspaceBytes.count))
        encoded.appendUInt16(UInt16(paneBytes.count))
        encoded.appendUInt16(UInt16(userBytes.count))
        encoded.appendUInt16(0)
        encoded.appendUInt32(UInt32(bytes.count))
        encoded.append(workspaceBytes)
        encoded.append(paneBytes)
        encoded.append(userBytes)
        encoded.append(bytes)
        return encoded
    }

    /// Decodes one complete frame and rejects unsupported or non-canonical data.
    public static func decode(_ encoded: Data) throws -> WorkspaceShareTerminalFrame {
        guard encoded.count >= Self.headerByteCount else {
            throw WorkspaceShareTerminalFrameError.truncated
        }
        guard encoded.count < ShareProtocolConstants.binaryFrameByteLimit else {
            throw WorkspaceShareTerminalFrameError.frameTooLarge
        }
        guard encoded.bytes(in: 0..<4).elementsEqual(Self.magic) else {
            throw WorkspaceShareTerminalFrameError.invalidMagic
        }
        guard encoded.byte(at: 4) == Self.wireVersion else {
            throw WorkspaceShareTerminalFrameError.unsupportedVersion
        }
        guard let kind = Kind(rawValue: encoded.byte(at: 5)) else {
            throw WorkspaceShareTerminalFrameError.unsupportedKind
        }
        guard encoded.uint16(at: 6) == 0 else {
            throw WorkspaceShareTerminalFrameError.unsupportedFlags
        }
        guard encoded.uint16(at: 50) == 0 else {
            throw WorkspaceShareTerminalFrameError.invalidReservedField
        }

        let workspaceByteCount = Int(encoded.uint16(at: 44))
        let paneByteCount = Int(encoded.uint16(at: 46))
        let userByteCount = Int(encoded.uint16(at: 48))
        let payloadByteCount = Int(encoded.uint32(at: 52))
        try Self.validateFrameSize(
            workspaceByteCount: workspaceByteCount,
            paneByteCount: paneByteCount,
            userByteCount: userByteCount,
            payloadByteCount: payloadByteCount
        )

        let expectedByteCount = Self.headerByteCount
            + workspaceByteCount
            + paneByteCount
            + userByteCount
            + payloadByteCount
        guard expectedByteCount == encoded.count else {
            throw WorkspaceShareTerminalFrameError.invalidLength
        }

        var offset = Self.headerByteCount
        let workspaceData = encoded.bytes(
            in: offset..<(offset + workspaceByteCount)
        )
        offset += workspaceByteCount
        let paneData = encoded.bytes(in: offset..<(offset + paneByteCount))
        offset += paneByteCount
        let userData = encoded.bytes(in: offset..<(offset + userByteCount))
        offset += userByteCount
        let payload = encoded.bytes(in: offset..<(offset + payloadByteCount))

        guard let workspaceID = String(data: workspaceData, encoding: .utf8) else {
            throw WorkspaceShareTerminalFrameError.invalidWorkspaceID
        }
        guard let paneID = String(data: paneData, encoding: .utf8) else {
            throw WorkspaceShareTerminalFrameError.invalidPaneID
        }
        let userID: String?
        if userData.isEmpty {
            userID = nil
        } else {
            guard let decodedUserID = String(data: userData, encoding: .utf8) else {
                throw WorkspaceShareTerminalFrameError.invalidUserID
            }
            userID = decodedUserID
        }

        return try WorkspaceShareTerminalFrame(
            kind: kind,
            streamEpoch: Self.decodeEpoch(encoded.bytes(in: 8..<24)),
            sequenceStart: encoded.uint64(at: 24),
            sequenceEnd: encoded.uint64(at: 32),
            rows: encoded.uint16(at: 40),
            columns: encoded.uint16(at: 42),
            workspaceID: workspaceID,
            paneID: paneID,
            userID: userID,
            bytes: payload
        )
    }

    private enum IdentifierField {
        case workspace
        case pane
        case user
    }

    private static let magic: [UInt8] = Array("CMXS".utf8)
    private static let zeroEpochBytes = Data(repeating: 0, count: 16)

    private static func validateIdentifier(
        _ value: String,
        field: IdentifierField
    ) throws {
        let byteCount = value.utf8.count
        let isValid = byteCount > 0
            && byteCount <= ShareProtocolConstants.maximumIDBytes
            && byteCount <= Int(UInt16.max)
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
        guard isValid else {
            switch field {
            case .workspace:
                throw WorkspaceShareTerminalFrameError.invalidWorkspaceID
            case .pane:
                throw WorkspaceShareTerminalFrameError.invalidPaneID
            case .user:
                throw WorkspaceShareTerminalFrameError.invalidUserID
            }
        }
    }

    private static func validateFrameSize(
        workspaceByteCount: Int,
        paneByteCount: Int,
        userByteCount: Int,
        payloadByteCount: Int
    ) throws {
        guard workspaceByteCount <= Int(UInt16.max),
              paneByteCount <= Int(UInt16.max),
              userByteCount <= Int(UInt16.max),
              payloadByteCount <= Int(UInt32.max) else {
            throw WorkspaceShareTerminalFrameError.invalidLength
        }

        let totalByteCount = Self.headerByteCount
            + workspaceByteCount
            + paneByteCount
            + userByteCount
            + payloadByteCount
        guard totalByteCount < ShareProtocolConstants.binaryFrameByteLimit else {
            throw WorkspaceShareTerminalFrameError.frameTooLarge
        }
    }

    private static func validateSemantics(
        kind: Kind,
        streamEpoch: UUID?,
        sequenceStart: UInt64,
        sequenceEnd: UInt64,
        rows: UInt16,
        columns: UInt16,
        userID: String?,
        payloadByteCount: Int
    ) throws {
        let hasNonzeroEpoch = streamEpoch.map {
            epochBytes($0) != zeroEpochBytes
        } ?? false

        switch kind {
        case .baseline:
            guard hasNonzeroEpoch,
                  sequenceStart == sequenceEnd,
                  rows > 0,
                  columns > 0,
                  userID == nil else {
                throw WorkspaceShareTerminalFrameError.invalidSemantics
            }

        case .output:
            let (expectedEnd, overflow) = sequenceStart.addingReportingOverflow(
                UInt64(payloadByteCount)
            )
            let hasCanonicalGeometry = (rows == 0 && columns == 0)
                || (rows > 0 && columns > 0)
            guard hasNonzeroEpoch,
                  !overflow,
                  sequenceEnd == expectedEnd,
                  hasCanonicalGeometry,
                  userID == nil else {
                throw WorkspaceShareTerminalFrameError.invalidSemantics
            }

        case .input:
            guard streamEpoch == nil,
                  sequenceStart == 0,
                  sequenceEnd == 0,
                  rows == 0,
                  columns == 0,
                  userID == nil,
                  payloadByteCount > 0,
                  payloadByteCount
                      <= ShareProtocolConstants.maximumTerminalInputBytes else {
                throw WorkspaceShareTerminalFrameError.invalidSemantics
            }

        case .forwardedInput:
            guard streamEpoch == nil,
                  sequenceStart == 0,
                  sequenceEnd == 0,
                  rows == 0,
                  columns == 0,
                  userID != nil,
                  payloadByteCount > 0,
                  payloadByteCount
                      <= ShareProtocolConstants.maximumTerminalInputBytes else {
                throw WorkspaceShareTerminalFrameError.invalidSemantics
            }
        }
    }

    private static func epochBytes(_ epoch: UUID?) -> Data {
        guard let epoch else { return zeroEpochBytes }
        let value = epoch.uuid
        return Data([
            value.0, value.1, value.2, value.3,
            value.4, value.5, value.6, value.7,
            value.8, value.9, value.10, value.11,
            value.12, value.13, value.14, value.15,
        ])
    }

    private static func decodeEpoch(_ data: Data) -> UUID? {
        guard data != zeroEpochBytes else { return nil }
        let bytes = Array(data)
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    }
}

public enum WorkspaceShareTerminalFrameError: Error, Equatable, Sendable {
    case truncated
    case frameTooLarge
    case invalidMagic
    case unsupportedVersion
    case unsupportedKind
    case unsupportedFlags
    case invalidReservedField
    case invalidLength
    case invalidWorkspaceID
    case invalidPaneID
    case invalidUserID
    case invalidSemantics
}

private extension Data {
    func byte(at offset: Int) -> UInt8 {
        self[index(startIndex, offsetBy: offset)]
    }

    func bytes(in offsets: Range<Int>) -> Data {
        let lowerBound = index(startIndex, offsetBy: offsets.lowerBound)
        let upperBound = index(startIndex, offsetBy: offsets.upperBound)
        return Data(self[lowerBound..<upperBound])
    }

    func uint16(at offset: Int) -> UInt16 {
        UInt16(byte(at: offset)) << 8
            | UInt16(byte(at: offset + 1))
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(byte(at: offset)) << 24
            | UInt32(byte(at: offset + 1)) << 16
            | UInt32(byte(at: offset + 2)) << 8
            | UInt32(byte(at: offset + 3))
    }

    func uint64(at offset: Int) -> UInt64 {
        UInt64(byte(at: offset)) << 56
            | UInt64(byte(at: offset + 1)) << 48
            | UInt64(byte(at: offset + 2)) << 40
            | UInt64(byte(at: offset + 3)) << 32
            | UInt64(byte(at: offset + 4)) << 24
            | UInt64(byte(at: offset + 5)) << 16
            | UInt64(byte(at: offset + 6)) << 8
            | UInt64(byte(at: offset + 7))
    }

    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUInt64(_ value: UInt64) {
        append(UInt8(truncatingIfNeeded: value >> 56))
        append(UInt8(truncatingIfNeeded: value >> 48))
        append(UInt8(truncatingIfNeeded: value >> 40))
        append(UInt8(truncatingIfNeeded: value >> 32))
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}

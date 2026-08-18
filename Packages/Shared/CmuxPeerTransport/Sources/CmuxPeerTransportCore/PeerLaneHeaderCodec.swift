public import Foundation

/// Encodes and decodes the bounded binary prefix on every cmux peer stream.
///
/// Wire layout, all integers big-endian:
/// `magic(8) | version(1) | lane(1) | flags(1) | credential(1) | payloadByteCount(4) | payload`.
public struct PeerLaneHeaderCodec: Sendable {
    private enum LaneCode {
        static let control: UInt8 = 1
        static let serverEvents: UInt8 = 2
        static let terminal: UInt8 = 3
        static let artifact: UInt8 = 4
    }

    private static let cursorPresentFlag: UInt8 = 1
    private static let pairGrantCredentialCode: UInt8 = 1

    private let configuration: PeerProtocolConfiguration
    private let fixedPrefixByteCount: Int

    /// Creates a codec for one protocol configuration.
    ///
    /// - Parameter configuration: The magic, version, and hard frame-size limit.
    /// - Throws: ``PeerLaneHeaderCodecError/invalidConfiguration`` when the
    ///   limit cannot contain even the fixed prefix.
    public init(configuration: PeerProtocolConfiguration = .cmuxMobileV2) throws {
        let fixedPrefixByteCount = configuration.headerMagic.count + 8
        guard !configuration.headerMagic.isEmpty,
              configuration.maximumHeaderByteCount >= fixedPrefixByteCount
        else {
            throw PeerLaneHeaderCodecError.invalidConfiguration
        }
        self.configuration = configuration
        self.fixedPrefixByteCount = fixedPrefixByteCount
    }

    /// Encodes a validated header into its complete binary frame.
    ///
    /// - Parameter header: The lane declaration to encode.
    /// - Returns: The binary header bytes to write before application data.
    /// - Throws: ``PeerLaneHeaderCodecError`` when the frame violates a limit.
    public func encode(_ header: PeerLaneHeader) throws -> Data {
        var payload = PeerBinaryWriter()
        let laneCode: UInt8
        let flags: UInt8
        let credentialCode: UInt8

        switch header {
        case let .control(credential):
            laneCode = LaneCode.control
            flags = 0
            credentialCode = Self.pairGrantCredentialCode
            try appendPairGrant(credential, to: &payload)

        case let .serverEvents(cursor):
            laneCode = LaneCode.serverEvents
            flags = cursor == nil ? 0 : Self.cursorPresentFlag
            credentialCode = 0
            if let cursor {
                payload.append(cursor)
            }

        case let .terminal(resourceID, cursor):
            laneCode = LaneCode.terminal
            flags = cursor == nil ? 0 : Self.cursorPresentFlag
            credentialCode = 0
            appendResourceID(resourceID, to: &payload)
            if let cursor {
                payload.append(cursor)
            }

        case let .artifact(resourceID, offset):
            laneCode = LaneCode.artifact
            flags = 0
            credentialCode = 0
            appendResourceID(resourceID, to: &payload)
            payload.append(offset)
        }

        let totalByteCount = fixedPrefixByteCount + payload.data.count
        guard totalByteCount <= configuration.maximumHeaderByteCount,
              let payloadByteCount = UInt32(exactly: payload.data.count)
        else {
            throw PeerLaneHeaderCodecError.headerTooLarge(totalByteCount)
        }

        var frame = PeerBinaryWriter(capacity: totalByteCount)
        frame.append(contentsOf: configuration.headerMagic)
        frame.append(configuration.headerVersion)
        frame.append(laneCode)
        frame.append(flags)
        frame.append(credentialCode)
        frame.append(payloadByteCount)
        frame.append(contentsOf: payload.data)
        return frame.data
    }

    /// Decodes one header prefix while preserving any following application bytes.
    ///
    /// - Parameter data: Bytes beginning at the start of a peer stream.
    /// - Returns: The header and exact byte count consumed from `data`.
    /// - Throws: ``PeerLaneHeaderCodecError`` or a field validation error.
    public func decodePrefix(_ data: Data) throws -> PeerDecodedLaneHeader {
        do {
            return try decodeValidatedPrefix(data)
        } catch is PeerBinaryCursor.Failure {
            // Truncated or non-UTF-8 field inside a well-framed payload.
            throw PeerLaneHeaderCodecError.invalidPayload
        }
    }

    private func decodeValidatedPrefix(_ data: Data) throws -> PeerDecodedLaneHeader {
        guard data.count >= fixedPrefixByteCount else {
            throw PeerLaneHeaderCodecError.incompleteFrame(
                requiredByteCount: fixedPrefixByteCount
            )
        }

        var prefix = PeerBinaryCursor(data: data.prefix(fixedPrefixByteCount))
        guard try prefix.readData(byteCount: configuration.headerMagic.count)
            == configuration.headerMagic
        else {
            throw PeerLaneHeaderCodecError.invalidMagic
        }
        let version = try prefix.readUInt8()
        guard version == configuration.headerVersion else {
            throw PeerLaneHeaderCodecError.unsupportedVersion(version)
        }
        let laneCode = try prefix.readUInt8()
        let flags = try prefix.readUInt8()
        let credentialCode = try prefix.readUInt8()
        let payloadByteCount = Int(try prefix.readUInt32())
        let totalByteCount = fixedPrefixByteCount + payloadByteCount
        guard totalByteCount <= configuration.maximumHeaderByteCount else {
            throw PeerLaneHeaderCodecError.headerTooLarge(totalByteCount)
        }
        guard data.count >= totalByteCount else {
            throw PeerLaneHeaderCodecError.incompleteFrame(requiredByteCount: totalByteCount)
        }

        let payloadStart = data.index(data.startIndex, offsetBy: fixedPrefixByteCount)
        let payloadEnd = data.index(payloadStart, offsetBy: payloadByteCount)
        var payload = PeerBinaryCursor(data: data[payloadStart ..< payloadEnd])
        let header = try decodeHeader(
            laneCode: laneCode,
            flags: flags,
            credentialCode: credentialCode,
            payload: &payload
        )
        guard payload.remainingByteCount == 0 else {
            throw PeerLaneHeaderCodecError.invalidPayload
        }
        return PeerDecodedLaneHeader(header: header, consumedByteCount: totalByteCount)
    }

    private func decodeHeader(
        laneCode: UInt8,
        flags: UInt8,
        credentialCode: UInt8,
        payload: inout PeerBinaryCursor
    ) throws -> PeerLaneHeader {
        switch laneCode {
        case LaneCode.control:
            guard flags == 0 else {
                throw PeerLaneHeaderCodecError.invalidFlags(flags)
            }
            guard credentialCode == Self.pairGrantCredentialCode else {
                throw PeerLaneHeaderCodecError.invalidCredentialKind(credentialCode)
            }
            let tokenByteCount = Int(try payload.readUInt16())
            let token = try payload.readString(byteCount: tokenByteCount)
            return .control(credential: try PeerPairGrantCredential(token: token))

        case LaneCode.serverEvents:
            try validateNonControl(flags: flags, credentialCode: credentialCode)
            return .serverEvents(cursor: try optionalCursor(flags: flags, payload: &payload))

        case LaneCode.terminal:
            try validateNonControl(flags: flags, credentialCode: credentialCode)
            let resourceID = try readResourceID(payload: &payload)
            let cursor = try optionalCursor(flags: flags, payload: &payload)
            return .terminal(resourceID: resourceID, cursor: cursor)

        case LaneCode.artifact:
            guard flags == 0 else {
                throw PeerLaneHeaderCodecError.invalidFlags(flags)
            }
            guard credentialCode == 0 else {
                throw PeerLaneHeaderCodecError.invalidCredentialKind(credentialCode)
            }
            let resourceID = try readResourceID(payload: &payload)
            return .artifact(resourceID: resourceID, offset: try payload.readUInt64())

        default:
            throw PeerLaneHeaderCodecError.unknownLane(laneCode)
        }
    }

    private func validateNonControl(flags: UInt8, credentialCode: UInt8) throws {
        guard flags & ~Self.cursorPresentFlag == 0 else {
            throw PeerLaneHeaderCodecError.invalidFlags(flags)
        }
        guard credentialCode == 0 else {
            throw PeerLaneHeaderCodecError.invalidCredentialKind(credentialCode)
        }
    }

    private func optionalCursor(
        flags: UInt8,
        payload: inout PeerBinaryCursor
    ) throws -> UInt64? {
        flags & Self.cursorPresentFlag == 0 ? nil : try payload.readUInt64()
    }

    private func readResourceID(payload: inout PeerBinaryCursor) throws -> PeerResourceID {
        let byteCount = Int(try payload.readUInt8())
        return try PeerResourceID(payload.readString(byteCount: byteCount))
    }

    private func appendPairGrant(
        _ credential: PeerPairGrantCredential,
        to payload: inout PeerBinaryWriter
    ) throws {
        let bytes = Data(credential.token.utf8)
        guard let byteCount = UInt16(exactly: bytes.count) else {
            throw PeerLaneHeaderCodecError.invalidPayload
        }
        payload.append(byteCount)
        payload.append(contentsOf: bytes)
    }

    private func appendResourceID(
        _ resourceID: PeerResourceID,
        to payload: inout PeerBinaryWriter
    ) {
        // PeerResourceID guarantees 1...128 bytes, so UInt8 always fits.
        let bytes = Data(resourceID.value.utf8)
        payload.append(UInt8(bytes.count))
        payload.append(contentsOf: bytes)
    }
}

public import Foundation

/// Encodes and decodes the bounded binary prefix on every cmux Iroh stream.
public struct CmxIrohStreamHeaderCodec: Sendable {
    private static let magic = Data("CMUXIRH1".utf8)
    private static let version: UInt8 = 1
    private static let fixedPrefixByteCount = 16
    private static let cursorPresentFlag: UInt8 = 1

    private let configuration: CmxIrohProtocolConfiguration

    /// Creates a codec for one protocol configuration.
    ///
    /// - Parameter configuration: The ALPN and hard frame-size limit.
    /// - Throws: ``CmxIrohStreamHeaderCodecError/invalidConfiguration`` when the limit is too small.
    public init(
        configuration: CmxIrohProtocolConfiguration = .cmuxMobileV1
    ) throws {
        guard configuration.maximumHeaderByteCount >= Self.fixedPrefixByteCount else {
            throw CmxIrohStreamHeaderCodecError.invalidConfiguration
        }
        self.configuration = configuration
    }

    /// Encodes a validated header into its complete binary frame.
    ///
    /// - Parameter header: The lane declaration to encode.
    /// - Returns: The binary header bytes to write before application data.
    /// - Throws: ``CmxIrohStreamHeaderCodecError`` when the frame violates a limit.
    public func encode(_ header: CmxIrohStreamHeader) throws -> Data {
        var payload = Data()
        let laneCode: UInt8
        let flags: UInt8
        let credentialCode: UInt8

        switch header.lane {
        case .control:
            laneCode = 1
            flags = 0
            guard let credential = header.credential else {
                throw CmxIrohStreamHeaderCodecError.invalidPayload
            }
            switch credential.kind {
            case .pairGrant:
                credentialCode = 1
                guard let token = credential.pairGrantToken else {
                    throw CmxIrohStreamHeaderCodecError.invalidPayload
                }
                try appendLengthPrefixedString(token, lengthByteCount: 2, to: &payload)
            case .offlinePairing:
                credentialCode = 2
                guard let attestation = credential.endpointAttestation,
                      let invitationID = credential.invitationID,
                      let proof = credential.offlineProof,
                      proof.count == 32
                else {
                    throw CmxIrohStreamHeaderCodecError.invalidPayload
                }
                try appendLengthPrefixedString(attestation, lengthByteCount: 2, to: &payload)
                try appendLengthPrefixedString(invitationID.value, lengthByteCount: 1, to: &payload)
                payload.append(proof)
            }

        case let .serverEvents(cursor):
            laneCode = 2
            credentialCode = 0
            flags = cursor == nil ? 0 : Self.cursorPresentFlag
            if let cursor {
                append(cursor, to: &payload)
            }

        case let .terminal(resourceID, cursor):
            laneCode = 3
            credentialCode = 0
            flags = cursor == nil ? 0 : Self.cursorPresentFlag
            try appendLengthPrefixedString(resourceID.value, lengthByteCount: 1, to: &payload)
            if let cursor {
                append(cursor, to: &payload)
            }

        case let .artifact(resourceID, offset):
            laneCode = 4
            credentialCode = 0
            flags = 0
            try appendLengthPrefixedString(resourceID.value, lengthByteCount: 1, to: &payload)
            append(offset, to: &payload)
        }

        let totalByteCount = Self.fixedPrefixByteCount + payload.count
        guard totalByteCount <= configuration.maximumHeaderByteCount else {
            throw CmxIrohStreamHeaderCodecError.headerTooLarge(totalByteCount)
        }
        guard let payloadByteCount = UInt32(exactly: payload.count) else {
            throw CmxIrohStreamHeaderCodecError.headerTooLarge(totalByteCount)
        }

        var frame = Self.magic
        frame.append(Self.version)
        frame.append(laneCode)
        frame.append(flags)
        frame.append(credentialCode)
        append(payloadByteCount, to: &frame)
        frame.append(payload)
        return frame
    }

    /// Decodes one header prefix while preserving any following application bytes.
    ///
    /// - Parameter data: Bytes beginning at the start of an Iroh stream.
    /// - Returns: The header and exact byte count consumed from `data`.
    /// - Throws: ``CmxIrohStreamHeaderCodecError`` or a field validation error.
    public func decodePrefix(_ data: Data) throws -> CmxIrohDecodedStreamHeader {
        guard data.count >= Self.fixedPrefixByteCount else {
            throw CmxIrohStreamHeaderCodecError.incompleteFrame(
                requiredByteCount: Self.fixedPrefixByteCount
            )
        }

        var prefix = CmxIrohBinaryCursor(data: data.prefix(Self.fixedPrefixByteCount))
        guard try prefix.readData(byteCount: Self.magic.count) == Self.magic else {
            throw CmxIrohStreamHeaderCodecError.invalidMagic
        }
        let version = try prefix.readUInt8()
        guard version == Self.version else {
            throw CmxIrohStreamHeaderCodecError.unsupportedVersion(version)
        }
        let laneCode = try prefix.readUInt8()
        let flags = try prefix.readUInt8()
        let credentialCode = try prefix.readUInt8()
        let payloadByteCount = Int(try prefix.readUInt32())
        let totalByteCount = Self.fixedPrefixByteCount + payloadByteCount
        guard totalByteCount <= configuration.maximumHeaderByteCount else {
            throw CmxIrohStreamHeaderCodecError.headerTooLarge(totalByteCount)
        }
        guard data.count >= totalByteCount else {
            throw CmxIrohStreamHeaderCodecError.incompleteFrame(requiredByteCount: totalByteCount)
        }

        let payloadStart = data.index(data.startIndex, offsetBy: Self.fixedPrefixByteCount)
        let payloadEnd = data.index(payloadStart, offsetBy: payloadByteCount)
        var payload = CmxIrohBinaryCursor(data: data[payloadStart ..< payloadEnd])
        let header = try decodeHeader(
            laneCode: laneCode,
            flags: flags,
            credentialCode: credentialCode,
            payload: &payload
        )
        guard payload.remainingByteCount == 0 else {
            throw CmxIrohStreamHeaderCodecError.invalidPayload
        }
        return CmxIrohDecodedStreamHeader(
            header: header,
            consumedByteCount: totalByteCount
        )
    }

    private func decodeHeader(
        laneCode: UInt8,
        flags: UInt8,
        credentialCode: UInt8,
        payload: inout CmxIrohBinaryCursor
    ) throws -> CmxIrohStreamHeader {
        switch laneCode {
        case 1:
            guard flags == 0 else {
                throw CmxIrohStreamHeaderCodecError.invalidFlags(flags)
            }
            let credential = try decodeCredential(code: credentialCode, payload: &payload)
            return try CmxIrohStreamHeader(lane: .control, credential: credential)
        case 2:
            try validateNonControl(flags: flags, credentialCode: credentialCode)
            let cursor = try optionalCursor(flags: flags, payload: &payload)
            return try CmxIrohStreamHeader(lane: .serverEvents(cursor: cursor))
        case 3:
            try validateNonControl(flags: flags, credentialCode: credentialCode)
            let resourceID = try readResourceID(payload: &payload)
            let cursor = try optionalCursor(flags: flags, payload: &payload)
            return try CmxIrohStreamHeader(lane: .terminal(resourceID: resourceID, cursor: cursor))
        case 4:
            guard flags == 0 else {
                throw CmxIrohStreamHeaderCodecError.invalidFlags(flags)
            }
            guard credentialCode == 0 else {
                throw CmxIrohStreamHeaderCodecError.invalidCredentialKind(credentialCode)
            }
            let resourceID = try readResourceID(payload: &payload)
            let offset = try payload.readUInt64()
            return try CmxIrohStreamHeader(lane: .artifact(resourceID: resourceID, offset: offset))
        default:
            throw CmxIrohStreamHeaderCodecError.unknownLane(laneCode)
        }
    }

    private func decodeCredential(
        code: UInt8,
        payload: inout CmxIrohBinaryCursor
    ) throws -> CmxIrohAdmissionCredential {
        switch code {
        case 1:
            let length = Int(try payload.readUInt16())
            return try .pairGrant(payload.readString(byteCount: length))
        case 2:
            let attestationLength = Int(try payload.readUInt16())
            let attestation = try payload.readString(byteCount: attestationLength)
            let invitationLength = Int(try payload.readUInt8())
            let invitationID = try CmxIrohResourceID(
                payload.readString(byteCount: invitationLength)
            )
            let proof = try payload.readData(byteCount: 32)
            return try .offlinePairing(
                endpointAttestation: attestation,
                invitationID: invitationID,
                proof: proof
            )
        default:
            throw CmxIrohStreamHeaderCodecError.invalidCredentialKind(code)
        }
    }

    private func validateNonControl(flags: UInt8, credentialCode: UInt8) throws {
        guard flags & ~Self.cursorPresentFlag == 0 else {
            throw CmxIrohStreamHeaderCodecError.invalidFlags(flags)
        }
        guard credentialCode == 0 else {
            throw CmxIrohStreamHeaderCodecError.invalidCredentialKind(credentialCode)
        }
    }

    private func optionalCursor(
        flags: UInt8,
        payload: inout CmxIrohBinaryCursor
    ) throws -> UInt64? {
        flags & Self.cursorPresentFlag == 0 ? nil : try payload.readUInt64()
    }

    private func readResourceID(
        payload: inout CmxIrohBinaryCursor
    ) throws -> CmxIrohResourceID {
        let length = Int(try payload.readUInt8())
        return try CmxIrohResourceID(payload.readString(byteCount: length))
    }

    private func appendLengthPrefixedString(
        _ value: String,
        lengthByteCount: Int,
        to data: inout Data
    ) throws {
        let bytes = Data(value.utf8)
        switch lengthByteCount {
        case 1:
            guard let length = UInt8(exactly: bytes.count) else {
                throw CmxIrohStreamHeaderCodecError.invalidPayload
            }
            data.append(length)
        case 2:
            guard let length = UInt16(exactly: bytes.count) else {
                throw CmxIrohStreamHeaderCodecError.invalidPayload
            }
            append(length, to: &data)
        default:
            throw CmxIrohStreamHeaderCodecError.invalidPayload
        }
        data.append(bytes)
    }

    private func append(_ value: UInt16, to data: inout Data) {
        let bigEndian = value.bigEndian
        withUnsafeBytes(of: bigEndian) { data.append(contentsOf: $0) }
    }

    private func append(_ value: UInt32, to data: inout Data) {
        let bigEndian = value.bigEndian
        withUnsafeBytes(of: bigEndian) { data.append(contentsOf: $0) }
    }

    private func append(_ value: UInt64, to data: inout Data) {
        let bigEndian = value.bigEndian
        withUnsafeBytes(of: bigEndian) { data.append(contentsOf: $0) }
    }
}

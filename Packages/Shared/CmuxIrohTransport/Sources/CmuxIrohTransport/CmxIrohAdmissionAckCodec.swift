public import Foundation

/// Encodes fixed eight-byte frames for the acknowledged admission barrier.
public struct CmxIrohAdmissionAckCodec: Sendable {
    /// The exact number of bytes consumed by every admission frame.
    public static let frameByteCount = 8

    private static let magic = Data("CMXA".utf8)
    private static let version: UInt8 = 1

    /// Creates an admission-frame codec.
    public init() {}

    /// Encodes the server's initial admission decision.
    ///
    /// - Parameter decision: The accepted or coded-denial result.
    /// - Returns: Exactly ``frameByteCount`` bytes.
    public func encode(_ decision: CmxIrohAdmissionDecision) -> Data {
        let frame: CmxIrohAdmissionFrame = switch decision {
        case .accepted:
            .acceptedPendingNatTraversal
        case let .denied(code):
            .denied(code: code)
        }
        return encodeFrame(frame)
    }

    /// Encodes one admission-barrier frame.
    ///
    /// - Parameter frame: The role-specific admission frame.
    /// - Returns: Exactly ``frameByteCount`` bytes.
    public func encodeFrame(_ frame: CmxIrohAdmissionFrame) -> Data {
        let status: UInt8
        let code: UInt16
        switch frame {
        case .acceptedPendingNatTraversal:
            status = 0
            code = 0
        case .acceptedRelayOnly:
            status = 4
            code = 0
        case let .denied(denialCode):
            status = 1
            code = denialCode
        case .clientReady:
            status = 2
            code = 0
        case .serverReady:
            status = 3
            code = 0
        }
        var frame = Self.magic
        frame.append(Self.version)
        frame.append(status)
        let bigEndian = code.bigEndian
        withUnsafeBytes(of: bigEndian) { frame.append(contentsOf: $0) }
        return frame
    }

    /// Decodes the first complete server decision.
    ///
    /// - Parameter data: Bytes beginning at the server decision.
    /// - Returns: The validated decision.
    /// - Throws: ``CmxIrohAdmissionAckCodecError`` for malformed input.
    public func decodePrefix(_ data: Data) throws -> CmxIrohAdmissionDecision {
        switch try decodeFramePrefix(data) {
        case .acceptedPendingNatTraversal, .acceptedRelayOnly:
            return .accepted
        case let .denied(code):
            return .denied(code: code)
        case let frame:
            throw CmxIrohAdmissionAckCodecError.invalidDecisionFrame(frame)
        }
    }

    /// Decodes the first complete role-specific admission frame.
    ///
    /// - Parameter data: Bytes beginning at the admission frame.
    /// - Returns: The validated frame.
    /// - Throws: ``CmxIrohAdmissionAckCodecError`` for malformed input.
    public func decodeFramePrefix(_ data: Data) throws -> CmxIrohAdmissionFrame {
        guard data.count >= Self.frameByteCount else {
            throw CmxIrohAdmissionAckCodecError.incompleteFrame
        }
        var cursor = CmxIrohBinaryCursor(data: data.prefix(Self.frameByteCount))
        guard try cursor.readData(byteCount: Self.magic.count) == Self.magic else {
            throw CmxIrohAdmissionAckCodecError.invalidMagic
        }
        let version = try cursor.readUInt8()
        guard version == Self.version else {
            throw CmxIrohAdmissionAckCodecError.unsupportedVersion(version)
        }
        let status = try cursor.readUInt8()
        let code = try cursor.readUInt16()
        switch status {
        case 0:
            guard code == 0 else {
                throw CmxIrohAdmissionAckCodecError.invalidAcceptedCode(code)
            }
            return .acceptedPendingNatTraversal
        case 1:
            return .denied(code: code)
        case 2:
            guard code == 0 else {
                throw CmxIrohAdmissionAckCodecError.invalidReadyCode(
                    status: status,
                    code: code
                )
            }
            return .clientReady
        case 3:
            guard code == 0 else {
                throw CmxIrohAdmissionAckCodecError.invalidReadyCode(
                    status: status,
                    code: code
                )
            }
            return .serverReady
        case 4:
            guard code == 0 else {
                throw CmxIrohAdmissionAckCodecError.invalidAcceptedCode(code)
            }
            return .acceptedRelayOnly
        default:
            throw CmxIrohAdmissionAckCodecError.invalidStatus(status)
        }
    }
}

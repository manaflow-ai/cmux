public import Foundation

/// Encodes the fixed eight-byte response to a control-stream admission header.
public struct CmxIrohAdmissionAckCodec: Sendable {
    /// The exact number of bytes consumed by every admission response.
    public static let frameByteCount = 8

    private static let magic = Data("CMXA".utf8)
    private static let version: UInt8 = 1

    /// Creates an admission-response codec.
    public init() {}

    /// Encodes an admission decision.
    ///
    /// - Parameter decision: The accepted or coded-denial result.
    /// - Returns: Exactly ``frameByteCount`` bytes.
    public func encode(_ decision: CmxIrohAdmissionDecision) -> Data {
        let status: UInt8
        let code: UInt16
        switch decision {
        case .accepted:
            status = 0
            code = 0
        case let .denied(denialCode):
            status = 1
            code = denialCode
        }
        var frame = Self.magic
        frame.append(Self.version)
        frame.append(status)
        let bigEndian = code.bigEndian
        withUnsafeBytes(of: bigEndian) { frame.append(contentsOf: $0) }
        return frame
    }

    /// Decodes the first complete admission response.
    ///
    /// - Parameter data: Bytes beginning at the admission response.
    /// - Returns: The validated decision.
    /// - Throws: ``CmxIrohAdmissionAckCodecError`` for malformed input.
    public func decodePrefix(_ data: Data) throws -> CmxIrohAdmissionDecision {
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
            return .accepted
        case 1:
            return .denied(code: code)
        default:
            throw CmxIrohAdmissionAckCodecError.invalidStatus(status)
        }
    }
}

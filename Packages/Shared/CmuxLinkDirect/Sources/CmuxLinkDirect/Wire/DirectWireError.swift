/// A peer sent bytes that break the direct wire (b4-direct.md section 4).
public enum DirectWireError: Error, Sendable, Hashable {
    case truncated
    case unknownRecordType(UInt8)
    case unknownReliability(UInt8)
    case unknownPriority(UInt8)
    case unsupportedVersion(UInt8)
    case recordTooLarge(Int)
    case frameTooLarge(Int)
    case wrongHost
}

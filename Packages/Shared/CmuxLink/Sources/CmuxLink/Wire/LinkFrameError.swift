/// A frame that does not decode.
public enum LinkFrameError: Error, Sendable, Hashable {
    case truncated
    case unsupportedVersion(UInt8)
    case unknownKind(UInt8)
    case invalidField(String)
    case trailingBytes
}

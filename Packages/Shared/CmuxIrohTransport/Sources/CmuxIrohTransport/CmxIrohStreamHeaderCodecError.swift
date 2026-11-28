/// Binary framing failures while encoding or decoding an Iroh stream header.
public enum CmxIrohStreamHeaderCodecError: Error, Equatable, Sendable {
    /// The configured frame limit cannot contain even the fixed prefix.
    case invalidConfiguration

    /// More bytes are needed before the complete header can be decoded.
    case incompleteFrame(requiredByteCount: Int)

    /// The stream did not begin with the cmux Iroh protocol marker.
    case invalidMagic

    /// The peer selected a stream-header version this build does not implement.
    case unsupportedVersion(UInt8)

    /// The peer selected an unknown lane code.
    case unknownLane(UInt8)

    /// Reserved flag bits were set for the selected lane.
    case invalidFlags(UInt8)

    /// The credential discriminator is invalid for the selected lane.
    case invalidCredentialKind(UInt8)

    /// The declared header exceeds the configured hard limit.
    case headerTooLarge(Int)

    /// A length, UTF-8 field, or lane payload violates the binary contract.
    case invalidPayload
}

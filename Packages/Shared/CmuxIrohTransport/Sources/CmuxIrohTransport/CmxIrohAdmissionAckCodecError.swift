/// Binary framing failures for a control-stream admission response.
public enum CmxIrohAdmissionAckCodecError: Error, Equatable, Sendable {
    /// Fewer than eight response bytes are available.
    case incompleteFrame

    /// The response did not begin with the cmux admission marker.
    case invalidMagic

    /// The response version is unsupported.
    case unsupportedVersion(UInt8)

    /// The response status discriminator is unknown.
    case invalidStatus(UInt8)

    /// An accepted response carried a nonzero denial code.
    case invalidAcceptedCode(UInt16)
}

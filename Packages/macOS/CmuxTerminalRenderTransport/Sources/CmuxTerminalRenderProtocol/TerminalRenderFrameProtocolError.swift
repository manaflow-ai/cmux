/// A validation or fixed-width metadata codec failure.
public enum TerminalRenderFrameProtocolError: Error, Equatable, Sendable {
    /// The bootstrap service name is empty, oversized, or contains a NUL byte.
    case invalidServiceName

    /// The worker capability does not have the required fixed length.
    case invalidCapabilityLength

    /// A worker process identity contains an invalid process ID.
    case invalidWorkerIdentity

    /// Frame width, height, or total pixel count exceeds protocol bounds.
    case invalidDimensions

    /// A damage rectangle is empty, overflows, or exceeds the frame bounds.
    case invalidDamageBounds

    /// A completion fence has an invalid zero signal value.
    case invalidCompletionFence

    /// Metadata had a byte count other than ``TerminalRenderFrameProtocol/metadataLength``.
    case invalidWireLength

    /// Metadata did not begin with the frame-plane magic bytes.
    case invalidWireMagic

    /// Metadata uses a wire version this implementation cannot decode.
    case unsupportedWireVersion(UInt16)

    /// Metadata sets flag bits this implementation does not understand.
    case unsupportedWireFlags(UInt16)

    /// Metadata contains a pixel format this implementation does not support.
    case unsupportedPixelFormat(UInt32)

    /// Metadata contains a color space this implementation does not support.
    case unsupportedColorSpace(UInt32)

    /// Metadata sets reserved bytes that must remain zero.
    case nonzeroReservedBytes

    /// The fixed-width record ended before the requested field was decoded.
    case truncatedWireRecord
}

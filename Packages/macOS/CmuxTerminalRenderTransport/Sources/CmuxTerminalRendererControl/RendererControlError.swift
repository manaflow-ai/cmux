/// A fail-closed renderer-control framing, validation, or lifecycle error.
public enum RendererControlError: Error, Equatable, Sendable {
    /// The four-byte frame magic did not match this protocol.
    case invalidMagic
    /// The peer used a version this implementation does not understand.
    case unsupportedVersion(UInt16)
    /// The peer used a noncanonical header length.
    case invalidHeaderLength(UInt16)
    /// The direction byte was unknown.
    case unknownDirection(UInt8)
    /// A decoder received a frame for the opposite direction.
    case unexpectedDirection
    /// The message type byte was unknown or invalid for its direction.
    case unknownMessageType(UInt8)
    /// Header flags contained a bit this version does not define.
    case unknownFlags(UInt16)
    /// A reserved field was nonzero.
    case nonzeroReserved
    /// A per-direction sequence was replayed or skipped.
    case invalidSequence(expected: UInt64, actual: UInt64)
    /// No contiguous sequence value remains after `UInt64.max`.
    case sequenceExhausted
    /// The payload length was invalid for the declared message type.
    case invalidPayloadLength
    /// The stream ended before one declared frame was complete.
    case truncatedFrame
    /// A fixed or length-delimited payload had unconsumed bytes.
    case trailingPayload
    /// An identity UUID was all zeroes.
    case zeroIdentity
    /// A renderer epoch was zero.
    case zeroRendererEpoch
    /// A presentation generation was zero.
    case zeroPresentationGeneration
    /// Presentation pixel dimensions exceeded the frame-plane limits.
    case invalidDimensions
    /// The backing scale was zero, non-finite, or unreasonably large.
    case invalidScale
    /// The pixel format value was unknown.
    case unknownPixelFormat(UInt32)
    /// The color-space value was unknown.
    case unknownColorSpace(UInt32)
    /// The Mach bootstrap service name was malformed.
    case invalidServiceName
    /// The frame-plane capability did not have the exact required length.
    case invalidCapabilityLength
    /// The resolved render configuration exceeded its allocation budget.
    case resolvedConfigTooLarge
    /// The opaque Ghostty semantic scene exceeded its allocation budget.
    case semanticSceneTooLarge
    /// A fatal diagnostic exceeded its allocation budget.
    case diagnosticTooLarge
    /// A length-delimited string was not valid UTF-8.
    case invalidUTF8
    /// The worker advertised a capability bit this version does not define.
    case unknownSceneCapabilities(UInt64)
    /// A needs-full-scene reason was unknown.
    case unknownNeedsFullSceneReason(UInt32)
    /// A fatal error code was unknown.
    case unknownFatalCode(UInt32)
    /// The ready message did not identify a live process.
    case invalidProcessIdentity
    /// Worker-owned grid metrics or their scene fence were zero or out of bounds.
    case invalidPresentationMetrics
    /// A message violated the session lifecycle or presentation ownership.
    case invalidTransition
    /// The incremental decoder was already poisoned by an earlier error.
    case decoderFailed
}

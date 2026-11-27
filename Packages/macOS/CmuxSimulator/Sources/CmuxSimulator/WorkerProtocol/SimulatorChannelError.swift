/// An outbound framing failure on a Simulator worker pipe.
public enum SimulatorChannelError: Error, Equatable, Sendable {
    /// The peer closed its input or the descriptor failed while writing.
    case writeFailed
    /// The payload exceeds ``SimulatorLengthPrefixedMessageChannel/maximumFrameLength``.
    case frameTooLarge
}

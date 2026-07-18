/// A renderer frame-plane resource or Mach transport failure.
public enum TerminalRenderFrameTransportError: Error, Equatable, Sendable {
    /// Secure random capability generation failed with the supplied Security status.
    case randomCapabilityFailed(Int32)

    /// The requested Mach queue limit is outside the package's bounded range.
    case invalidQueueLimit

    /// Swift and the C bridge disagree about fixed capability or metadata sizes.
    case bridgeContractMismatch

    /// The receive timeout exceeds the cancellation-latency bound.
    case invalidReceiveTimeout

    /// Mach receive endpoint creation failed with the supplied kernel error.
    case receiverCreationFailed(Int32)

    /// Bootstrap lookup of the frame send right failed with the supplied kernel error.
    case senderConnectionFailed(Int32)

    /// A nonblocking frame send failed with the supplied kernel error.
    case sendFailed(Int32)

    /// A bounded frame receive failed with the supplied kernel error.
    case receiveFailed(Int32)

    /// Another receive operation is already using this receiver.
    case receiveAlreadyInProgress

    /// The supervisor has not yet bound the receiver to a worker audit identity.
    case workerNotAuthorized

    /// The receiver was already bound to a different worker identity.
    case workerAlreadyAuthorized

    /// The sender or receiver has been stopped explicitly.
    case stopped
}

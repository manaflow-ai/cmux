/// Delivery progress of an outgoing message, for tick rendering.
public enum ChatDeliveryState: Sendable, Equatable {
    /// Waiting to be sent (offline or send in flight not yet started).
    case queued
    /// The send call is in flight.
    case sending
    /// The host acknowledged delivery (one tick).
    case delivered
    /// The send failed; the associated text is a human-readable reason.
    case failed(String)
}

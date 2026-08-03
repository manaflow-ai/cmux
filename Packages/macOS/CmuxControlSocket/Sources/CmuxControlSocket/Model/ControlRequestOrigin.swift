/// Identifies whether a control request originated inside cmux or arrived over
/// a socket whose authorization was already accepted by the listener.
public enum ControlRequestOrigin: Sendable {
    /// A trusted call made directly by cmux rather than by a socket client.
    case inProcess

    /// A socket call carrying the immutable authorization accepted for it.
    case socket(ControlSocketRequestAuthorization)
}

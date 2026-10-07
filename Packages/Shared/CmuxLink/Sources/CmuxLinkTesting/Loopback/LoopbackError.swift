/// Failures the loopback and simulated carriers inject.
public enum LoopbackError: Error, Sendable, Hashable {
    case refused
    case closed
    case mediaUnsupported
    case frameTooLarge(Int)
}

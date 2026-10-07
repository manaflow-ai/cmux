public enum InMemoryUnderlayError: Error, Sendable, Hashable {
    case closed
    case tooLarge
    case refused
}

/// The terminal result of an app-lifetime push settings mutation.
enum MobilePushMutationOutcome: Sendable, Equatable {
    case completed
    case timedOut
    case cancelled
}

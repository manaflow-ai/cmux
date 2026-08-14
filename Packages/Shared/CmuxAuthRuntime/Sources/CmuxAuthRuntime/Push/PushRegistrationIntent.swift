/// A coordinator preference and its monotonic ordering token.
struct PushRegistrationIntent: Sendable, Equatable {
    let enabled: Bool
    let generation: UInt64
}

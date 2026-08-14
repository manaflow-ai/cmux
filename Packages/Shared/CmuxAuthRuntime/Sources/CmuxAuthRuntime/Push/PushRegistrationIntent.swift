struct PushRegistrationIntent: Sendable, Equatable {
    let enabled: Bool
    let kind: PushRegistrationIntentKind
    let generation: UInt64
}

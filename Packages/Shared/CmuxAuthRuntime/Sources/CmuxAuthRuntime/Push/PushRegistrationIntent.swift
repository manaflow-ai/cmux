/// The preference mutation operation and its service-owned ordering token.
enum PushRegistrationIntentKind: Sendable, Equatable {
    /// The regular `setEnabled(_:)` semantics, including retrying an already
    /// disabled owner's pending cleanup instead of inferring a live owner.
    case setEnabled
    /// The coordinator's local-first opt-out cleanup semantics.
    case disableAndUnregister
}

struct PushRegistrationIntent: Sendable, Equatable {
    let enabled: Bool
    let kind: PushRegistrationIntentKind
    let generation: UInt64
}

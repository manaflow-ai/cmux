/// The preference mutation operation represented by a service intent.
enum PushRegistrationIntentKind: Sendable, Equatable {
    /// The regular `setEnabled(_:)` semantics, including retrying an already
    /// disabled owner's pending cleanup instead of inferring a live owner.
    case setEnabled
    /// The coordinator's local-first opt-out cleanup semantics.
    case disableAndUnregister
}

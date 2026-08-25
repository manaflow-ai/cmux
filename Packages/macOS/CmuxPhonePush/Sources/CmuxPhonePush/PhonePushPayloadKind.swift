/// The operation encoded in a phone-push request.
public enum PhonePushPayloadKind: String, Sendable {
    /// A visible mirror of one Mac notification.
    case notify
    /// A silent banner-removal and badge update.
    case dismiss
}

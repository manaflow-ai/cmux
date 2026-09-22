#if os(iOS)

/// The recovery action category for a failed notification deep link.
public enum MobilePushTabUnavailableAlertKind: Equatable, Sendable {
    /// The requested workspace or terminal no longer exists.
    case tabUnavailable
}
#endif

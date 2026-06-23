/// Presentation mode for the mobile connection-recovery banner.
enum MobileConnectionRecoveryBannerPresentation: Equatable {
    /// No recovery banner should be visible.
    case none
    /// The connected Mac requires a different authenticated account.
    case reauth(String?)
    /// Automatic reconnect failed and the user can retry.
    case lost
    /// Automatic reconnect is in progress while cached shell state remains visible.
    case reconnecting
}

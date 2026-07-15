import Foundation

/// Applies the user's bandwidth preference to a Sparkle update archive request.
struct UpdateDownloadNetworkPolicy: Sendable {
    /// Whether an automatic download may use Personal Hotspot, cellular, or Low Data Mode.
    let allowsMeteredAutomaticDownloads: Bool

    /// Constrains `request` unless the user explicitly initiated this download.
    ///
    /// - Parameters:
    ///   - request: Sparkle's mutable archive request.
    ///   - userInitiated: Whether the user explicitly chose to install this update.
    func apply(to request: NSMutableURLRequest, userInitiated: Bool) {
        let allowsMeteredAccess = userInitiated || allowsMeteredAutomaticDownloads
        request.allowsExpensiveNetworkAccess = allowsMeteredAccess
        request.allowsConstrainedNetworkAccess = allowsMeteredAccess
    }
}

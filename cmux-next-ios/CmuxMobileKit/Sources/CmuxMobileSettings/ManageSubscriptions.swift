#if os(iOS)
// Its own file: StoreKit's `AppStore` would clash with CmuxMobileModel's
// `AppStore` in files that import both.
import StoreKit
import UIKit

/// Apple's own subscription management sheet
/// (`AppStore.showManageSubscriptions(in:)`), or Apple's subscriptions page
/// when StoreKit cannot show it (no foreground window scene, no App Store
/// account, an error).
@MainActor
func openAppStoreSubscriptionManagement(fallback: URL) async {
    let scene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }
    if let scene {
        do {
            try await AppStore.showManageSubscriptions(in: scene)
            return
        } catch {}
    }
    await UIApplication.shared.open(fallback)
}
#endif

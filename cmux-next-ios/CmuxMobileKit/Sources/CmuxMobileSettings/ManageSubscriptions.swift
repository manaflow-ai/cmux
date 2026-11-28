#if os(iOS)
// StoreKit through CmuxMobileSystemUI.framework: linked, StoreKit costs the
// app about 1.55 s before `main` on a cold launch.
import CmuxMobileSystemUIBridge
import UIKit

/// Apple's own subscription management sheet
/// (`AppStore.showManageSubscriptions(in:)`), or Apple's subscriptions page
/// when StoreKit cannot show it (no foreground window scene, no App Store
/// account, an error, or the framework did not load).
@MainActor
func openAppStoreSubscriptionManagement(fallback: URL) async {
    let scene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }
    if let scene, let provider = SystemUI.provider {
        let shown = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            provider.showManageSubscriptions(in: scene) { error in
                continuation.resume(returning: error == nil)
            }
        }
        if shown { return }
    }
    await UIApplication.shared.open(fallback)
}
#endif

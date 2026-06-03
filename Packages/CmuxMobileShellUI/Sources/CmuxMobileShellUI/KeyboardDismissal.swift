#if os(iOS)
import UIKit
#endif

/// Resigns the keyboard across every window in the active scene.
///
/// Both the sign-in flow and the terminal chrome need to dismiss the soft
/// keyboard before presenting a sheet/popover; this is the one shared
/// implementation (previously copy-pasted as a private `dismissKeyboard()` in
/// `SignInView` and `WorkspaceDetailView`). No-op on non-iOS.
@MainActor
func dismissMobileKeyboard() {
    #if os(iOS)
    for scene in UIApplication.shared.connectedScenes {
        guard let windowScene = scene as? UIWindowScene else { continue }
        for window in windowScene.windows {
            window.endEditing(true)
        }
    }
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    #endif
}

import UIKit

extension UIApplication {
    /// Resigns the keyboard across every window in every connected scene.
    ///
    /// Both the sign-in flow and the terminal chrome need to dismiss the soft
    /// keyboard before presenting a sheet/popover; this is the one shared
    /// implementation (previously copy-pasted as a private `dismissKeyboard()`
    /// in `SignInView` and `WorkspaceDetailView`).
    @MainActor
    func dismissMobileKeyboard() {
        for scene in connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.endEditing(true)
            }
        }
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

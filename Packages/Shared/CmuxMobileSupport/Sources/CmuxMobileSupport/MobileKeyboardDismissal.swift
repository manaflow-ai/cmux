#if canImport(UIKit)
public import UIKit

extension UIApplication {
    /// Resigns the keyboard across every window in every connected scene.
    ///
    /// The sign-in flow, the terminal chrome, and the browser-stream chrome all
    /// need to dismiss the soft keyboard regardless of which responder raised
    /// it (address field, dialog text field, hidden input proxy); this is the
    /// one shared implementation.
    @MainActor
    public func dismissMobileKeyboard() {
        for scene in connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.endEditing(true)
            }
        }
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
#endif

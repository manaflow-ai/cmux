public import SwiftUI

/// The one Sign In button (``SignInButton``) in a SwiftUI view: the same AppKit button, so a SwiftUI
/// page and an AppKit card show the same control at the same density.
///
/// ```swift
/// if !signedIn {
///     Text(strings.signedOut)
///     SignInButtonView { services.signIn() }
/// }
/// ```
public struct SignInButtonView: NSViewRepresentable {
    let title: String
    let onSignIn: @MainActor () -> Void

    /// A button titled `title` that runs `onSignIn` when clicked.
    /// - Parameters:
    ///   - title: The title, "Sign In" by default.
    ///   - onSignIn: Starts the sign-in this place needs.
    public init(title: String = SignInButton.defaultTitle, onSignIn: @escaping @MainActor () -> Void) {
        self.title = title
        self.onSignIn = onSignIn
    }

    public func makeNSView(context: Context) -> SignInButton {
        SignInButton(title: title, onSignIn: onSignIn)
    }

    public func updateNSView(_ button: SignInButton, context: Context) {
        button.onSignIn = onSignIn
        button.retitle(title)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView button: SignInButton, context: Context) -> CGSize? {
        button.intrinsicContentSize
    }
}

public import AuthenticationServices
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The default ``AuthPresentationAnchoring`` conformer.
///
/// Resolves the active key window on iOS or macOS and returns it as the
/// presentation anchor for `ASWebAuthenticationSession` and
/// `ASAuthorizationController`. Construct it once at the app composition root
/// and inject it; it holds no mutable state and is safe to share.
public final class AuthPresentationContextProvider: NSObject, AuthPresentationAnchoring {
    /// Creates a presentation-anchor provider.
    public override init() {
        super.init()
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        resolveAnchor()
    }

    public func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        resolveAnchor()
    }

    private func resolveAnchor() -> ASPresentationAnchor {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first { $0.activationState == .foregroundActive }
        if let anchorScene = activeScene ?? scenes.first {
            if let window = anchorScene.windows.first(where: { $0.isKeyWindow }) ?? anchorScene.windows.first {
                return window
            }
            return UIWindow(windowScene: anchorScene)
        }
        return UIWindow(frame: UIScreen.main.bounds)
        #elseif os(macOS)
        return resolveAnchor(
            keyWindow: NSApplication.shared.keyWindow,
            mainWindow: NSApplication.shared.mainWindow,
            firstWindow: NSApplication.shared.windows.first
        )
        #else
        preconditionFailure("AuthPresentationContextProvider: unsupported platform")
        #endif
    }

    #if os(macOS)
    /// Resolves the anchor from explicit window state. Internal so tests can
    /// deterministically exercise every branch — most importantly the
    /// no-window fallback invariant — without depending on the test host's
    /// live `NSApplication` window state.
    func resolveAnchor(
        keyWindow: NSWindow?,
        mainWindow: NSWindow?,
        firstWindow: NSWindow?
    ) -> ASPresentationAnchor {
        if let keyWindow {
            return keyWindow
        }
        if let window = mainWindow ?? firstWindow {
            return window
        }
        // Last-resort anchor when the app has no windows at all. It must stay
        // invisible and must never be made key: a bare NSWindow made key shows
        // up as an empty black zombie window (#7825 class of bugs).
        return NSWindow()
    }
    #endif
}

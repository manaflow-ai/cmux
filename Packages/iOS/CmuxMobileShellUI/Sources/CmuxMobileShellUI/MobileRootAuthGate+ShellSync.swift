import CmuxMobileShell
import CmuxMobileWorkspace
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

extension MobileRootAuthGate {
    /// Backwards-compatible static spelling for ``syncShellAuthentication(stackAuthenticated:isRestoringSession:store:)``.
    @MainActor
    public static func syncShellAuthentication(
        stackAuthenticated: Bool,
        isRestoringSession: Bool = false,
        store: CMUXMobileShellStore
    ) {
        MobileRootAuthGate().syncShellAuthentication(
            stackAuthenticated: stackAuthenticated,
            isRestoringSession: isRestoringSession,
            store: store
        )
    }

    /// Reflects Stack auth state into the legacy shell store's sign-in lifecycle.
    ///
    /// This bridge lives in the feature target because it reaches into the
    /// `CMUXMobileShellStore` god object, which sits above the pure
    /// ``MobileRootAuthGate`` policy in ``CmuxMobileWorkspace``.
    @MainActor
    func syncShellAuthentication(
        stackAuthenticated: Bool,
        isRestoringSession: Bool = false,
        store: CMUXMobileShellStore
    ) {
        if stackAuthenticated {
            store.signIn()
        } else if !isRestoringSession {
            store.signOut()
        }
    }
}

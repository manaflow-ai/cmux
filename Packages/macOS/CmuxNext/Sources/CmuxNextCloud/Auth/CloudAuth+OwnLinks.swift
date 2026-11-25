public import Foundation

extension CloudAuth {
    /// This build's own link a page handed back in cmux's own browser: GitHub's install redirect to
    /// `<scheme>://integration/complete` (``CloudGitHubCompletion/handle(_:auth:)``) or the sign-in callback. Finished
    /// here, as one from another browser is, and true; false for any other link, which the browser opens as before.
    @MainActor public func finishOwnLink(_ url: URL) -> Bool {
        if CloudGitHubCompletion.handle(url, auth: self) { return true }
        guard isCallback(url) else { return false }
        // task-owner: one callback per redirect; the sign-in flow owns its own state and timeout.
        Task { _ = await handleCallback(url) }
        return true
    }

    /// A sign-in callback macOS handed cmux: finished by the flow, or, when no flow took it and no sign-in holds,
    /// `showAccounts` (Settings > Accounts says why).
    @MainActor public func finishOpenedCallback(_ url: URL, showAccounts: @escaping @MainActor () -> Void) {
        // task-owner: one callback per opened URL, moved here from the app delegate as it was.
        Task {
            guard await !handleCallback(url) else { return }
            await awaitRestored()
            guard signInFailed, !isSignedIn, !isSigningIn else { return }
            showAccounts()
        }
    }
}

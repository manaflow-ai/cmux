package import Foundation
package import CmuxNextCompat

/// What a sign-in does with the store (pure rules; the tab runs the I/O).
package nonisolated struct BrowserHTTPSignInMemory: Sendable {
    package let store: any BrowserHTTPCredentialStoring
    package let offTheRecord: Bool

    /// The remembered login to use without asking: first try only.
    package func remembered(_ key: BrowserHTTPCredentialKey, failures: Int) -> BrowserHTTPRememberedLogin? {
        guard !offTheRecord, failures == 0 else { return nil }
        return store.login(for: key)
    }

    /// After the user answers: a checked Remember saves, an unchecked one
    /// forgets what was saved for that server, and Cancel after a failed try
    /// forgets it too (the saved password was wrong). Off the record: nothing.
    package func record(_ response: BrowserPromptResponse, for key: BrowserHTTPCredentialKey, failures: Int) {
        guard !offTheRecord else { return }
        guard case .credentials(let user, let password, let remember) = response else {
            if failures > 0 { store.forget(key) }
            return
        }
        if remember {
            store.save(BrowserHTTPRememberedLogin(user: user, password: password), for: key)
        } else {
            store.forget(key)
        }
    }

    package init(store: any BrowserHTTPCredentialStoring, offTheRecord: Bool) {
        self.store = store
        self.offTheRecord = offTheRecord
    }
}

import Foundation
import Synchronization

/// The store for tests and previews.
nonisolated final class InMemoryHTTPCredentialStore: BrowserHTTPCredentialStoring {
    private let logins = Mutex<[BrowserHTTPCredentialKey: BrowserHTTPRememberedLogin]>([:])

    func login(for key: BrowserHTTPCredentialKey) -> BrowserHTTPRememberedLogin? { logins.withLock { $0[key] } }
    func save(_ login: BrowserHTTPRememberedLogin, for key: BrowserHTTPCredentialKey) { logins.withLock { $0[key] = login } }
    func forget(_ key: BrowserHTTPCredentialKey) { _ = logins.withLock { $0.removeValue(forKey: key) } }
}

/// What a sign-in does with the store (pure rules; the tab runs the I/O).
nonisolated struct BrowserHTTPSignInMemory: Sendable {
    let store: any BrowserHTTPCredentialStoring
    let offTheRecord: Bool

    /// The remembered login to use without asking: first try only.
    func remembered(_ key: BrowserHTTPCredentialKey, failures: Int) -> BrowserHTTPRememberedLogin? {
        guard !offTheRecord, failures == 0 else { return nil }
        return store.login(for: key)
    }

    /// After the user answers: a checked Remember saves, an unchecked one
    /// forgets what was saved for that server, and Cancel after a failed try
    /// forgets it too (the saved password was wrong). Off the record: nothing.
    func record(_ response: BrowserPromptResponse, for key: BrowserHTTPCredentialKey, failures: Int) {
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
}

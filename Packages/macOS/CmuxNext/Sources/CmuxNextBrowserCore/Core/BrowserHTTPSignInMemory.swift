package import Foundation
package import CmuxNextCompat

/// What a sign-in does with the store (pure rules; the tab runs the I/O).
///
/// `index` is the App's remembered sign-ins in memory (``BrowserSharedStores``' `httpSignIns`, listed at launch):
/// a challenge it can answer needs no Keychain call (``cached(_:failures:)``); the Keychain read and write
/// (``remembered(_:failures:)``, ``write(_:for:)``) block, so the tab runs them on the system lane.
package nonisolated struct BrowserHTTPSignInMemory: Sendable {
    /// One change an answer makes to what is remembered.
    package enum Change: Equatable, Sendable {
        case save(BrowserHTTPRememberedLogin)
        case forget
    }

    package let store: any BrowserHTTPCredentialStoring
    package let index: RememberedSecretIndex<BrowserHTTPRememberedLogin>?
    package let offTheRecord: Bool

    /// What memory knows for the first try (later tries and off the record: nothing remembered), with no
    /// Keychain call: ``RememberedSecretIndex/Answer/unknown`` sends the tab to ``remembered(_:failures:)``.
    package func cached(_ key: BrowserHTTPCredentialKey, failures: Int) -> RememberedSecretIndex<BrowserHTTPRememberedLogin>.Answer {
        guard !offTheRecord, failures == 0 else { return .absent }
        return index?.answer(for: key.account) ?? .unknown
    }

    /// The remembered login to use without asking, read from the Keychain (blocking): first try only. Memory
    /// keeps the answer for the next challenge.
    package func remembered(_ key: BrowserHTTPCredentialKey, failures: Int) -> BrowserHTTPRememberedLogin? {
        guard !offTheRecord, failures == 0 else { return nil }
        let login = store.login(for: key)
        index?.note(login, for: key.account)
        return login
    }

    /// After the user answers: a checked Remember saves, an unchecked one
    /// forgets what was saved for that server, and Cancel after a failed try
    /// forgets it too (the saved password was wrong). Off the record: nothing.
    package func change(after response: BrowserPromptResponse, failures: Int) -> Change? {
        guard !offTheRecord else { return nil }
        guard case .credentials(let user, let password, let remember) = response else { return failures > 0 ? .forget : nil }
        return remember ? .save(BrowserHTTPRememberedLogin(user: user, password: password)) : .forget
    }

    /// Applies `change` to memory now (no I/O), so the next challenge sees it before the Keychain write lands.
    package func apply(_ change: Change, for key: BrowserHTTPCredentialKey) {
        switch change {
        case .save(let login): index?.note(login, for: key.account)
        case .forget: index?.note(nil, for: key.account)
        }
    }

    /// Writes `change` to the Keychain (blocking).
    package func write(_ change: Change, for key: BrowserHTTPCredentialKey) {
        switch change {
        case .save(let login): store.save(login, for: key)
        case .forget: store.forget(key)
        }
    }

    package init(store: any BrowserHTTPCredentialStoring, index: RememberedSecretIndex<BrowserHTTPRememberedLogin>? = nil, offTheRecord: Bool) {
        self.store = store
        self.index = index
        self.offTheRecord = offTheRecord
    }
}

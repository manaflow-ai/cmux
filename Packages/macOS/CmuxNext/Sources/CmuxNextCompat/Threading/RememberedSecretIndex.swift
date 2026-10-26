/// Sign-ins the person chose to remember, in memory, so a challenge on an input path (a page load, a connect)
/// is answered without a Keychain round trip.
///
/// Chrome's password manager keeps the saved logins in memory once its store has loaded them at startup
/// (components/password_manager/core/browser/password_store/password_store.h), never asking the OS store on
/// a page load. Here the composition root lists the Keychain items' accounts on its system lane at launch
/// (``listed(_:)``: attributes only, no secret, so no Keychain access prompt); a server with no item then needs
/// no Keychain call. A secret is kept once read or saved this run (``note(_:for:)``); saves and forgets update it
/// before their Keychain write.
public final class RememberedSecretIndex<Secret: Sendable>: Sendable {
    /// What memory knows about one account.
    public enum Answer: Sendable {
        /// Nothing remembered: the list is loaded and has no item for it, or it was forgotten this run.
        case absent
        /// This secret.
        case secret(Secret)
        /// Only the Keychain knows: an item listed but not read yet, or the list is not loaded.
        case unknown
    }

    private enum Entry {
        case listed
        case secret(Secret)
        case forgotten
    }

    private struct State {
        var loaded = false
        var entries: [String: Entry] = [:]
    }

    // concurrency-allow: one dictionary read or write per call from the main thread (a challenge, an answer) and the
    // system lane (the launch list, a read); a short critical section with no I/O and no call out under it (lock carve-out).
    private let state = Mutex(State())

    public init() {}

    /// What memory knows about `account`.
    public func answer(for account: String) -> Answer {
        state.withLock { state -> Answer in
            switch state.entries[account] {
            case .secret(let secret): .secret(secret)
            case .forgotten: .absent
            case .listed: .unknown
            case nil: state.loaded ? .absent : .unknown
            }
        }
    }

    /// Keeps what the Keychain holds for `account` now: a secret read or saved, or nil when it holds none.
    public func note(_ secret: Secret?, for account: String) {
        state.withLock { $0.entries[account] = secret.map(Entry.secret) ?? .forgotten }
    }

    /// The Keychain's accounts at launch; nil when the list could not be read (memory then keeps answering
    /// ``Answer/unknown`` for accounts it has not seen). What this run read, saved or forgot stays as it is.
    public func listed(_ accounts: Set<String>?) {
        guard let accounts else { return }
        state.withLock { state in
            for account in accounts where state.entries[account] == nil { state.entries[account] = .listed }
            state.loaded = true
        }
    }
}

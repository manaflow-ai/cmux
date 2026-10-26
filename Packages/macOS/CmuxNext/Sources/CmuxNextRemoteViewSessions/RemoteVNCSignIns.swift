public import CmuxNextCompat
public import CmuxNextWakeups
public import CmuxVNC

/// The VNC sign-ins saved in the Keychain, in memory (``RememberedSecretIndex``), keyed by `host:port`. The
/// composition root owns one, lists it at launch (``RememberedSecretIndex/loadRememberedVNCSignIns(on:)``) and
/// gives it to every VNC tab, so a connect to a host with no saved sign-in, or one read before, waits for no
/// Keychain call.
public typealias RemoteVNCSignIns = RememberedSecretIndex<VNCCredentials>

extension RememberedSecretIndex where Secret == VNCCredentials {
    /// Lists the saved VNC sign-ins' accounts (no secret) into memory on `work`'s system lane. Development
    /// builds only, like VNC tabs; a release build lists nothing.
    public func loadRememberedVNCSignIns(on work: BackgroundWork) {
        #if DEBUG
        work.post(.bestEffort, mayBlock: .system) { [self] in listed(RemoteVNCCredentialStore().accounts()) }
        #endif
    }
}

/// The saved sign-in reads of one VNC session: memory first, else one read on the system lane (a person
/// waits for it) whose answer reaches main through the scheduler, unless a newer read or ``cancel()`` came
/// first; then the read's `dropped` runs instead.
@MainActor
final class RemoteVNCSignInReads {
    private let work: BackgroundWork
    private let mainWork: MainWorkScheduler
    private let memory: RemoteVNCSignIns
    private let account: String
    /// The Keychain's sign-in for `account` (blocking).
    private let keychain: @Sendable () -> VNCCredentials?
    /// The sign-in when the Keychain has none (a development file; blocking).
    private let fallback: @Sendable () -> VNCCredentials?
    /// The newest read: an older one's answer is dropped.
    private var generation = 0

    init(work: BackgroundWork, mainWork: MainWorkScheduler, memory: RemoteVNCSignIns, account: String,
         keychain: @escaping @Sendable () -> VNCCredentials?, fallback: @escaping @Sendable () -> VNCCredentials? = { nil }) {
        self.work = work
        self.mainWork = mainWork
        self.memory = memory
        self.account = account
        self.keychain = keychain
        self.fallback = fallback
    }

    /// Drops every read in flight (a stop, a close).
    func cancel() {
        generation += 1
    }

    /// Gives the saved sign-in (nil: none) to `then` on main: at once when memory knows the Keychain's answer
    /// and there is no fallback to read, else after the system lane read.
    func read(dropped: @escaping @MainActor @Sendable () -> Void = {}, then: @escaping @MainActor @Sendable (VNCCredentials?) -> Void) {
        generation += 1
        let read = generation, memory = memory, account = account, keychain = keychain, fallback = fallback
        let body: @Sendable () -> VNCCredentials?
        switch memory.answer(for: account) {
        case .secret(let saved):
            return then(saved)
        case .absent:
            body = fallback
        case .unknown:
            body = {
                let saved = keychain()
                memory.note(saved, for: account)
                return saved ?? fallback()
            }
        }
        work.run(.userBlocking, mayBlock: .system) { body() }
            .reply(on: mainWork, class: .visible, owner: "remoteVNC.savedSignIn") { [weak self] saved in
                guard let self, read == generation else { return dropped() }
                then(saved)
            }
    }

    /// Keeps a sign-in the host accepted in memory now (from any thread); the caller writes the Keychain on the
    /// system lane.
    nonisolated func saved(_ credentials: VNCCredentials) {
        memory.note(credentials, for: account)
    }
}

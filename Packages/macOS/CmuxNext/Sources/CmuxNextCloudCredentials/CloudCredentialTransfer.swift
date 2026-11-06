public import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextWakeups
public import Foundation

/// Only a native, target/team-scoped confirmation may call this. A repeat reuses the explicit
/// transfer cache; Retry after a rejected credential passes refresh:true to mint a replacement.
@MainActor public struct CloudCredentialTransfer {
    public enum Provider: String, Sendable, Equatable, Hashable { case claude, codex }
    public enum Failure: LocalizedError, Equatable {
        case consentRequired, scopeChanged, sharedMachine, machineNotReady, incompatibleConfiguration, copyTurnedOff
        case localLoginUnavailable, loginFailed, invalidCredential, storeFailed, deliveryFailed

        public var errorDescription: String? {
            switch self {
            case .consentRequired: "Confirm this machine and provider before transferring credentials."
            case .copyTurnedOff: "Copying your login to Cloud machines is off; sign in on the machine instead."
            case .scopeChanged: "The signed-in account or Cloud team changed; start the transfer again."
            case .sharedMachine: "Personal credentials can only be transferred to a Cloud machine you own."
            case .machineNotReady: "The Cloud machine is still setting up, so cmux can't confirm it's yours yet. Try again in a minute."
            case .incompatibleConfiguration: "The target's provider configuration conflicts with own login."
            case .localLoginUnavailable: "Open a local terminal to finish provider sign-in."
            case .loginFailed: "Provider sign-in did not complete; retry setup in cmux."
            case .invalidCredential: "Provider sign-in returned an invalid credential; retry setup in cmux."
            case .storeFailed: "cmux could not store the new credential securely."
            case .deliveryFailed: "The credential was not installed on the machine; retry setup in cmux."
            }
        }
    }

    let provider: Provider
    let machineID: String
    /// Nil is the authenticated user's personal Cloud scope; a non-nil value is a selected team.
    let teamID: String?
    let userID: String
    let openTerminal: @MainActor (String) async -> Bool
    /// DEV and dogfood builds only: a team guest whose creator is the caller (the platform's
    /// `vmKind == "owner"` answer, still required) may receive the login although teammates share its
    /// Unix user. Off everywhere else; the machine's daemon honors it only in a DEV daemon build.
    public let allowsCreatorTeamGuest: Bool
    /// How long the first guest check waits for a new guest's bind (``guestCheckBudget``; tests shorten it).
    var guestBudget = Self.guestCheckBudget
    /// The account's other teams (nil: its personal scope) whose cached login this transfer reuses when
    /// ``teamID`` holds none (``CloudCredentialLogin/loadAny(provider:teamID:otherTeams:userID:)``).
    public var otherTeams: [String?] = []

    public init(provider: Provider, machineID: String, teamID: String?, userID: String, allowsCreatorTeamGuest: Bool = false,
                otherTeams: [String?] = [], openTerminal: @escaping @MainActor (String) async -> Bool) {
        self.provider = provider; self.machineID = machineID; self.teamID = teamID; self.userID = userID
        self.allowsCreatorTeamGuest = allowsCreatorTeamGuest; self.otherTeams = otherTeams; self.openTerminal = openTerminal
    }

    /// How many times the guest check runs while the kind record is missing, ``guestCheckPause`` apart (3 s), and
    /// for how long at most, slow calls included: about 90 s, the journey's `waitPreflight` budget.
    public nonisolated static let guestCheckTries = 30
    public nonisolated static let guestCheckBudget: Duration = .seconds(90)
    /// No event says the guest has bound, so the checks are spaced as retries after a failure.
    @Sendable public nonisolated static func guestCheckPause() async throws {
        var backoff = Backoff(initial: .seconds(3), maximum: .seconds(3), multiplier: 1)
        // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
        try await backoff.wait(owner: "cloud-credential-transfer.guest-bind")
    }

    /// `operation`, cancelled at `deadline`: nil once the deadline is reached, before or while it runs.
    nonisolated static func before<T: Sendable>(_ deadline: ContinuousClock.Instant,
                                                _ operation: @escaping @Sendable () async throws -> T) async throws -> T? {
        try await before(deadline, clock: ContinuousClock(), operation)
    }

    /// ``before(_:_:)`` with `deadline` and the cut-off read on `clock`, so a test proves the budget on a
    /// clock it advances by hand instead of waiting for it in real time.
    nonisolated static func before<T: Sendable, C: Clock & Sendable>(_ deadline: C.Instant, clock: C,
                                                _ operation: @escaping @Sendable () async throws -> T) async throws -> T?
        where C.Duration == Duration {
        let left = clock.now.duration(to: deadline)
        guard left > .zero else { return nil }
        do { return try await withDeadline(left, label: "cloud guest bind", clock: clock, operation) } catch is DeadlineExceeded { return nil }
    }

    /// The guest-kind line of the chat restart after this transfer (the app's credential recovery):
    /// the kinds the transfer installs on, an owner guest, or with ``allowsCreatorTeamGuest`` (DEV and
    /// dogfood builds, cloud.startChat's own gate; production keeps requiring an owner guest) a team
    /// guest as well, so a team guest it installed on restarts too.
    public var restartGuestCheck: String {
        #"case "$(cat /etc/cmux/vm-kind 2>/dev/null)" in "# + (allowsCreatorTeamGuest ? "owner|team" : "owner") + ") ;; *) exit 1 ;; esac"
    }

    /// `callerOwnsVM`: the signed-in caller owns the machine, from the platform (the classic attach
    /// answer's `vmKind == "owner"`, which #28788 gives a team machine's creator, or a Worker
    /// machine's owner link), never from a guest file (the app's `CloudService.callerOwnsVM`).
    ///
    /// `stillAllowed`: asked last, right before the login is written (a Release build re-reads its
    /// remote switch and the person's consent there, since a confirm or a sign-in may have outlasted
    /// the switch's answer). False stops the copy with ``Failure/copyTurnedOff``.
    /// No default: every caller says what it re-reads, and a default async closure is a crash class.
    public func run(api: CloudAPIClient, currentTeamID: @MainActor () -> String?, currentUserID: @MainActor () -> String?, confirmed: Bool,
             refresh: Bool = false, callerOwnsVM: @escaping @Sendable () async throws -> Bool,
             stillAllowed: @escaping @Sendable () async -> Bool) async throws {
        let pinned = api.pinningTeam(teamID)
        try await run(currentTeamID: currentTeamID, currentUserID: currentUserID, confirmed: confirmed, refresh: refresh,
            effects: Effects(
                callerOwnsVM: callerOwnsVM,
                stillAllowed: stillAllowed,
                pause: Self.guestCheckPause,
                // Sealed on this Mac to the machine's daemon key and opened only there (`cmux carrier secrets`,
                // `secrets-v1`): the login never crosses an exec, a file API or the platform.
                install: { [provider, machineID, allowsCreatorTeamGuest] login in
                    try await pinned.installSealedLogin(machineID, harness: provider.rawValue, login: login,
                                                        allowTeamGuest: allowsCreatorTeamGuest)
                },
            // Codex auth.json is never reused as a seed: its refresh token is VM-bound and may
            // rotate. A new device login is required for every transfer; a broker can supersede this.
            load: { [otherTeams] in provider == .codex ? nil : try await CloudCredentialLogin.loadAny(provider: provider, teamID: teamID, otherTeams: otherTeams, userID: userID) },
                acquire: { try await CloudCredentialLogin.acquire(provider: provider, openTerminal: openTerminal) },
                // Codex auth.json contains a VM-bound refresh token. Never retain a second Mac copy;
                // each VM gets a fresh device login until a broker owns refresh persistence.
                store: { value in
                    if provider == .claude { try await CloudCredentialLogin.store(value, provider: provider, teamID: teamID, userID: userID, machineID: machineID) }
                }))
    }

    /// What cmux holds of this account's login: one, none, or a Keychain that did not answer (locked,
    /// `security` timed out or failed). Unreadable is never "none": a start that reads it passes no login
    /// either, but its record says the Keychain failed, not that the person never signed in.
    public enum CachedLogin: String, Sendable, Equatable {
        case cached, none, unreadable

        /// A start's record when it passes nothing for want of a cached login, and the chat's own
        /// "Sign in to Claude" card takes over; nil when there is one.
        public var startOutcome: String? {
            switch self {
            case .cached: nil
            case .none: "no cached login: the chat's Sign in to Claude card"
            case .unreadable: "cached login unreadable (the Keychain did not answer): the chat's Sign in to Claude card"
            }
        }

        /// `check`'s ``startOutcome``. A check cancelled with its start throws ``CancellationError``: the Keychain
        /// read the cancellation cut short is not a Keychain that did not answer.
        public static func startOutcome(_ check: () async -> Self) async throws -> String? {
            let cached = await check()
            try Task.checkCancellation()
            return cached.startOutcome
        }
    }

    /// Whether cmux already holds this account's login for `provider` (Claude only: a Codex login is
    /// never kept on the Mac), so a transfer needs no sign-in. Reads the Keychain; prompts nothing.
    public static func cachedLogin(provider: Provider, teamID: String?, userID: String, otherTeams: [String?] = []) async -> CachedLogin {
        guard provider == .claude else { return .none }
        return await cachedLogin { try await CloudCredentialLogin.loadAny(provider: provider, teamID: teamID, otherTeams: otherTeams, userID: userID) }
    }

    /// ``cachedLogin(provider:teamID:userID:otherTeams:)`` over `read`, the Keychain read.
    static func cachedLogin(_ read: () async throws -> Data?) async -> CachedLogin {
        do { return try await read() == nil ? .none : .cached } catch { return .unreadable }
    }

    public static func hasCachedLogin(provider: Provider, teamID: String?, userID: String, otherTeams: [String?] = []) async -> Bool {
        await cachedLogin(provider: provider, teamID: teamID, userID: userID, otherTeams: otherTeams) == .cached
    }

    nonisolated struct Effects: Sendable {
        var callerOwnsVM: @Sendable () async throws -> Bool
        var stillAllowed: @Sendable () async -> Bool = { true }
        /// Between guest checks while the guest has not bound yet (``guestCheckPause``). No default: a
        /// default async closure is a crash class.
        var pause: @Sendable () async throws -> Void
        /// Seals the login to the machine's daemon and sends it over its carrier; answers the machine's verdict.
        var install: @Sendable (Data) async throws -> CloudAPIClient.SealedDelivery
        var load: @Sendable () async throws -> Data?
        var acquire: @Sendable () async throws -> Data
        var store: @Sendable (Data) async throws -> Void
    }

    func run(currentTeamID: @MainActor () -> String?, currentUserID: @MainActor () -> String?, confirmed: Bool, refresh: Bool = false,
             effects: Effects) async throws {
        do {
            try await perform(currentTeamID: currentTeamID, currentUserID: currentUserID, confirmed: confirmed,
                              refresh: refresh, effects: effects)
        } catch let failure as Failure { throw failure
        } catch is CancellationError { throw CancellationError()
        } catch { throw Failure.deliveryFailed }
    }

    private func perform(currentTeamID: @MainActor () -> String?, currentUserID: @MainActor () -> String?, confirmed: Bool,
                         refresh: Bool, effects: Effects) async throws {
        guard confirmed else { throw Failure.consentRequired }
        func checkScope() throws {
            try Task.checkCancellation()
            guard !machineID.isEmpty, !userID.isEmpty, currentTeamID() == teamID, currentUserID() == userID else { throw Failure.scopeChanged }
        }
        try checkScope()
        // No credential is acquired or read until the platform says the caller owns the machine. The
        // guest's own kind, launchers and configuration are the machine daemon's to check (`secrets-v1`).
        guard try await effects.callerOwnsVM() else { throw Failure.sharedMachine }
        try checkScope()
        let cached = refresh ? nil : try await effects.load()
        let credential: Data
        if let cached { credential = cached } else { credential = try await effects.acquire() }
        try checkScope()
        try Self.validate(credential, provider: provider)
        if cached == nil { try await effects.store(credential) }
        try checkScope()
        // Recheck after browser/Keychain interaction; the target may have changed meanwhile.
        guard try await effects.callerOwnsVM() else { throw Failure.sharedMachine }
        guard await effects.stillAllowed() else { throw Failure.copyTurnedOff }
        try checkScope()
        try await installWhenBound(credential, effects: effects, checkScope: checkScope)
    }

    /// Sends the sealed login, again while the machine's guest has no kind record yet (its cmux-host writes
    /// /etc/cmux/vm-kind once it binds, which can land after the machine reads running): the daemon answers
    /// `not-ready` until then. A guest that is not the caller's owner guest is ``Failure/sharedMachine``; a record
    /// that never comes is ``Failure/machineNotReady``. Every send and pause counts against ``guestBudget``.
    private func installWhenBound(_ credential: Data, effects: Effects, checkScope: () throws -> Void) async throws {
        let deadline = ContinuousClock.now + guestBudget
        for attempt in 1...Self.guestCheckTries {
            let answer: CloudAPIClient.SealedDelivery
            do {
                guard let sent = try await Self.before(deadline, { try await effects.install(credential) }) else { break }
                answer = sent
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A transport error may carry a provider diagnostic; never surface it.
                throw Failure.deliveryFailed
            }
            switch answer {
            case .installed: return
            case .failed(code: "refused", refusal: "not-ready", retryable: _): break
            case .failed(code: "refused", refusal: "not-owner-guest", retryable: _): throw Failure.sharedMachine
            case .failed(code: "refused", refusal: "conflict", retryable: _): throw Failure.incompatibleConfiguration
            case .failed(code: "refused", refusal: "invalid-credential", retryable: _): throw Failure.invalidCredential
            case .failed(code: "unsupported", refusal: _, retryable: _): throw Failure.machineNotReady
            default: throw Failure.deliveryFailed
            }
            guard attempt < Self.guestCheckTries, try await Self.before(deadline, effects.pause) != nil else { break }
            try checkScope()
        }
        throw Failure.machineNotReady
    }

    nonisolated static func validate(_ data: Data, provider: Provider) throws {
        guard data.count <= 12_000 else { throw Failure.invalidCredential }
        switch provider {
        case .claude:
            guard let token = String(data: data, encoding: .utf8), token.hasPrefix("sk-ant-oat01-"),
                  token.count >= 32, token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw Failure.invalidCredential }
        case .codex:
            guard let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  auth["OPENAI_API_KEY"] is NSNull || auth["OPENAI_API_KEY"] == nil,
                  let tokens = auth["tokens"] as? [String: Any],
                  ["access_token", "refresh_token", "id_token"].allSatisfy({ (tokens[$0] as? String)?.isEmpty == false })
            else { throw Failure.invalidCredential }
        }
    }
}

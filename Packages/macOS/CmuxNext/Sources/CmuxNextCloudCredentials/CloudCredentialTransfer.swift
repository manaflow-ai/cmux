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
    /// DEV and dogfood builds only (``CloudCredentialInstaller/creatorTeamGuest``): a team guest
    /// whose creator is the caller (the platform's `vmKind == "owner"` answer, still required) may
    /// receive the login although teammates share its Unix user. Off everywhere else.
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

    /// The guest check this transfer runs before and after the login.
    var preflight: String { allowsCreatorTeamGuest ? CloudCredentialInstaller.creatorTeamPreflight : CloudCredentialInstaller.preflight }

    /// Exits 0 only while the guest has no kind record: its cmux-host writes /etc/cmux/vm-kind once it
    /// binds (`record_owner_kind`), which can land after the machine reads running and takes its first exec.
    nonisolated static let kindMissing = "[ ! -s /etc/cmux/vm-kind ]"
    /// How many times a guest check runs while the kind record is missing, ``guestCheckPause`` apart (3 s), and
    /// for how long at most, slow execs included: about 90 s, the journey's `waitPreflight` budget.
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
                exec: { try await pinned.exec(machineID, command: $0, timeoutMs: 20_000).exitCode },
                write: { try await Self.stage($1, at: $0, on: pinned, machineID: machineID) },
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

    /// Writes the credential where the installer reads it. The file routes write as root. Where exec
    /// runs as root too (`/api/vm`), the installer chowns a 0600 file before it drops to `cmux`. A
    /// Worker machine's exec runs as `cmux` and can't read a root 0600 file, so its folder is first
    /// made `cmux`'s own 0700 one (an exec as `cmux`), and the file goes in 0644: only `cmux` and
    /// root can reach it, as `deliver-secrets` stages its receiver.
    nonisolated static func stage(_ credential: Data, at path: String, on api: CloudAPIClient, machineID: String) async throws {
        guard api.execRunsAsWorkUser else { return try await api.writeFile(machineID, path: path, data: credential, mode: 0o600) }
        let folder = CloudCredentialInstaller.quote((path as NSString).deletingLastPathComponent)
        let made = try await api.exec(machineID, command: "umask 077 && mkdir -p -- \(folder) && chmod 700 -- \(folder) && test -O \(folder) && test ! -L \(folder)",
                                      timeoutMs: 20_000)
        guard made.exitCode == 0 else { throw Failure.deliveryFailed }
        try await api.writeFile(machineID, path: path, data: credential, mode: 0o644)
    }

    /// Whether cmux already holds this account's login for `provider` (Claude only: a Codex login is
    /// never kept on the Mac), so a transfer needs no sign-in. Reads the Keychain; prompts nothing.
    public static func hasCachedLogin(provider: Provider, teamID: String?, userID: String, otherTeams: [String?] = []) async -> Bool {
        guard provider == .claude else { return false }
        return ((try? await CloudCredentialLogin.loadAny(provider: provider, teamID: teamID, otherTeams: otherTeams, userID: userID)) ?? nil) != nil
    }

    nonisolated struct Effects: Sendable {
        var callerOwnsVM: @Sendable () async throws -> Bool
        var stillAllowed: @Sendable () async -> Bool = { true }
        /// Between guest checks while the guest has not bound yet (``guestCheckPause``). No default: a
        /// default async closure is a crash class.
        var pause: @Sendable () async throws -> Void
        var exec: @Sendable (String) async throws -> Int
        var write: @Sendable (String, Data) async throws -> Void
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
        // No credential is acquired or read until the platform says the caller owns the machine and
        // the machine has the image's launchers.
        guard try await effects.callerOwnsVM() else { throw Failure.sharedMachine }
        try await waitForGuest(program: preflight, effects: effects, checkScope: checkScope)
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
        guard try await effects.exec(preflight) == 0 else { throw Failure.sharedMachine }
        guard await effects.stillAllowed() else { throw Failure.copyTurnedOff }
        try checkScope()
        let path = "/home/cmux/.cmux/credential-transfer/\(UUID().uuidString).json"
        do {
            try checkScope()
            try await effects.write(path, credential)
            try checkScope()
            guard try await effects.exec(CloudCredentialInstaller.command(provider: provider, payloadPath: path, creatorTeamGuest: allowsCreatorTeamGuest)) == 0 else {
                throw Failure.deliveryFailed
            }
        } catch {
            // A failed/cancelled delivery must not leave a second readable copy on the target.
            // A cancelled caller cannot start an API request. An unstructured task has independent
            // cancellation; the production exec effect bounds its own request to 20 seconds.
            let cleanup = Task.detached(priority: .utility) {
                _ = try? await effects.exec("rm -f -- \(CloudCredentialInstaller.quote(path))")
            }
            await cleanup.value
            if error is CancellationError { throw CancellationError() }
            // API/CLI output may contain a provider diagnostic with a secret. Never surface it.
            throw Failure.deliveryFailed
        }
    }

    /// The first guest check, run again while the guest has no kind record yet (it has not bound). A kind
    /// record that fails the check is the guest's answer (a team guest, an image without the launchers):
    /// refused at once. A record that never comes is ``Failure/machineNotReady``.
    /// Every exec and pause counts against ``guestBudget``, slow ones included.
    private func waitForGuest(program: String, effects: Effects, checkScope: () throws -> Void) async throws {
        let deadline = ContinuousClock.now + guestBudget
        for attempt in 1...Self.guestCheckTries {
            guard let passed = try await Self.before(deadline, { try await effects.exec(program) }) else { break }
            if passed == 0 { return }
            guard let missing = try await Self.before(deadline, { try await effects.exec(Self.kindMissing) }) else { break }
            guard missing == 0 else { throw Failure.sharedMachine }
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

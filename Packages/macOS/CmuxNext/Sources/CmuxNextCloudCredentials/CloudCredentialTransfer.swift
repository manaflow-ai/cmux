public import CmuxNextCloud
import CmuxNextDaemon
public import Foundation

/// Only a native, target/team-scoped confirmation may call this. A repeat reuses the explicit
/// transfer cache; Retry after a rejected credential passes refresh:true to mint a replacement.
@MainActor public struct CloudCredentialTransfer {
    public enum Provider: String, Sendable, Equatable, Hashable { case claude, codex }
    public enum Failure: LocalizedError, Equatable {
        case consentRequired, scopeChanged, sharedMachine, incompatibleConfiguration
        case localLoginUnavailable, loginFailed, invalidCredential, storeFailed, deliveryFailed

        public var errorDescription: String? {
            switch self {
            case .consentRequired: "Confirm this machine and provider before transferring credentials."
            case .scopeChanged: "The signed-in account or Cloud team changed; start the transfer again."
            case .sharedMachine: "Personal credentials can only be transferred to a Cloud machine you own."
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

    public init(provider: Provider, machineID: String, teamID: String?, userID: String, allowsCreatorTeamGuest: Bool = false,
                openTerminal: @escaping @MainActor (String) async -> Bool) {
        self.provider = provider; self.machineID = machineID; self.teamID = teamID; self.userID = userID
        self.allowsCreatorTeamGuest = allowsCreatorTeamGuest; self.openTerminal = openTerminal
    }

    /// The guest check this transfer runs before and after the login.
    var preflight: String { allowsCreatorTeamGuest ? CloudCredentialInstaller.creatorTeamPreflight : CloudCredentialInstaller.preflight }

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
    public func run(api: CloudAPIClient, currentTeamID: @MainActor () -> String?, currentUserID: @MainActor () -> String?, confirmed: Bool,
             refresh: Bool = false, callerOwnsVM: @escaping @Sendable () async throws -> Bool) async throws {
        let pinned = api.pinningTeam(teamID)
        try await run(currentTeamID: currentTeamID, currentUserID: currentUserID, confirmed: confirmed, refresh: refresh,
            effects: Effects(
                callerOwnsVM: callerOwnsVM,
                exec: { try await pinned.exec(machineID, command: $0, timeoutMs: 20_000).exitCode },
                write: { try await Self.stage($1, at: $0, on: pinned, machineID: machineID) },
            // Codex auth.json is never reused as a seed: its refresh token is VM-bound and may
            // rotate. A new device login is required for every transfer; a broker can supersede this.
            load: { provider == .codex ? nil : try await CloudCredentialLogin.load(provider: provider, teamID: teamID, userID: userID, machineID: machineID) },
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
    public static func hasCachedLogin(provider: Provider, teamID: String?, userID: String) async -> Bool {
        guard provider == .claude else { return false }
        return ((try? await CloudCredentialLogin.load(provider: provider, teamID: teamID, userID: userID)) ?? nil) != nil
    }

    nonisolated struct Effects: Sendable {
        var callerOwnsVM: @Sendable () async throws -> Bool
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
        guard try await effects.exec(preflight) == 0 else { throw Failure.sharedMachine }
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

import CmuxNextCloud
import Foundation

/// Only a native, target/team-scoped confirmation may call this. A repeat reuses the explicit
/// transfer cache; Retry after a rejected credential passes refresh:true to mint a replacement.
@MainActor struct CloudCredentialTransfer {
    enum Provider: String, Sendable { case claude, codex }
    enum Failure: Error, Equatable {
        case consentRequired, scopeChanged, sharedMachine, incompatibleConfiguration
        case localLoginUnavailable, loginFailed, invalidCredential, storeFailed, deliveryFailed
    }

    let provider: Provider
    let machineID: String
    let teamID: String
    let userID: String
    let openTerminal: @MainActor (String) -> Bool

    func run(api: CloudAPIClient, currentTeamID: @MainActor () -> String?, currentUserID: @MainActor () -> String?, confirmed: Bool,
             refresh: Bool = false) async throws {
        let pinned = api.pinningTeam(teamID)
        try await run(currentTeamID: currentTeamID, currentUserID: currentUserID, confirmed: confirmed, refresh: refresh,
            effects: Effects(
                exec: { try await pinned.exec(machineID, command: $0, timeoutMs: 20_000).exitCode },
                write: { try await pinned.writeFile(machineID, path: $0, data: $1, mode: 0o600) },
                load: { try await CloudCredentialLogin.load(provider: provider, teamID: teamID, userID: userID) },
                acquire: { try await CloudCredentialLogin.acquire(provider: provider, openTerminal: openTerminal) },
                store: { try await CloudCredentialLogin.store($0, provider: provider, teamID: teamID, userID: userID) }))
    }

    struct Effects {
        var exec: (String) async throws -> Int
        var write: (String, Data) async throws -> Void
        var load: () async throws -> Data?
        var acquire: () async throws -> Data
        var store: (Data) async throws -> Void
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
            guard !teamID.isEmpty, !machineID.isEmpty, !userID.isEmpty, currentTeamID() == teamID, currentUserID() == userID else { throw Failure.scopeChanged }
        }
        try checkScope()
        // No credential is acquired/read until the authenticated target proves owner-only policy.
        guard try await effects.exec(CloudCredentialInstaller.preflight) == 0 else { throw Failure.sharedMachine }
        try checkScope()
        let cached = refresh ? nil : try await effects.load()
        let credential: Data
        if let cached { credential = cached } else { credential = try await effects.acquire() }
        try checkScope()
        try Self.validate(credential, provider: provider)
        if cached == nil { try await effects.store(credential) }
        try checkScope()
        // Recheck after browser/Keychain interaction; the target may have changed meanwhile.
        guard try await effects.exec(CloudCredentialInstaller.preflight) == 0 else { throw Failure.sharedMachine }
        let path = "/home/cmux/.cmux/credential-transfer/\(UUID().uuidString).json"
        do {
            try checkScope()
            try await effects.write(path, credential)
            try checkScope()
            guard try await effects.exec(CloudCredentialInstaller.command(provider: provider, payloadPath: path)) == 0 else {
                throw Failure.deliveryFailed
            }
        } catch {
            // A failed/cancelled delivery must not leave a second readable copy on the target.
            _ = try? await effects.exec("rm -f -- \(CloudCredentialInstaller.quote(path))")
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

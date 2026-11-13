public import CmuxNextCloud
public import Foundation

/// Reads the local identity facts used by Rust's receipt policy; it never contacts a guest.
@MainActor public struct CloudWarmLoginScope {
    public init() {}

    /// A failed Keychain or identity read supplies no proof. Rust compares the fingerprint and binding
    /// at registration, completion and start; changing either invalidates the earlier receipt.
    public func read(platform: URL, identity: MacInstallIdentity, userID: String, teamID: String?, otherTeams: [String?]) async -> CloudMoveCLI.SpareLoginScope? {
        do {
            let token = try await identity.installToken()
            guard let team = MacInstallIdentity.team(ofToken: token), let install = await identity.installID() else { return nil }
            let login = try await CloudCredentialLogin.loadAny(provider: .claude, teamID: teamID, otherTeams: otherTeams, userID: userID)
            // A successful nil is known absence; adding a local token later changes this digest.
            guard let fingerprint = CloudMachineLogin.fingerprint(login ?? Data()) else { return nil }
            return .init(platform: platform, team: team, install: install, credential: fingerprint)
        } catch { return nil }
    }
}

public import Foundation

/// A GitHub App token that lets git on this Mac clone one repository the cmux GitHub App reaches, for a
/// chat on this Mac started in a repository picked from the folder menu (``CloudGitHubPicker/cloneToken(repo:)``).
/// Asked of the same route a Cloud machine clones with (`POST /v1/integrations/github/token`), scoped to that
/// one repository and to reading its contents. The token is short-lived and goes only to that one `git clone`.
public nonisolated struct CloudGitHubCloneToken: Equatable, Sendable {
    /// The `ghs_…` installation token.
    public var token: String

    public init(token: String) { self.token = token }

    /// The daemon's `owner.github_clone_token` answer `{token}` (cmux-cloud-api checked the route's answer: a token for
    /// that repository with read permissions alone); nil for anything else, so no other text reaches git.
    static func parse(_ answer: Data) -> CloudGitHubCloneToken? {
        guard let object = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any],
              let token = object["token"] as? String, isInstallationToken(token) else { return nil }
        return CloudGitHubCloneToken(token: token)
    }

    /// GitHub's installation token: `ghs_` and letters, digits or `_`, at most 255 bytes.
    static func isInstallationToken(_ token: String) -> Bool {
        token.hasPrefix("ghs_") && token.utf8.count <= 255
            && token.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F }
    }
}

extension CloudGitHubPicker {
    /// A token to clone `repo` (`owner/name`) on this Mac, minted with this install's token in the team the
    /// picker lists repositories for (``owner()``); nil signed out, offline, or refused (the team's installation
    /// does not reach it). Never throws, never logs the token.
    public func cloneToken(repo: String) async -> CloudGitHubCloneToken? {
        guard CloudGitHubRepos.isFullName(repo), auth.isSignedIn,
              let install = try? await identity.installToken(awaitingBind: Self.bindWait),
              let team = MacInstallIdentity.team(ofToken: install) else { return nil }
        // The daemon's `owner.github_clone_token` with the install token as its credential (stdin, never argv) and no
        // team header: the request, its 20 s and the answer's checks are cmux-cloud-api's. The answer stays in this call.
        let client = CloudDaemon.workerMachines(baseURL: auth.configuration.ownerAPIBaseURL(), accessToken: { install }, teamID: { nil },
                                                   machineIO: auth.machineIO, buildSpace: auth.configuration.buildSpace)
        let args: [String: any Sendable] = ["team": team, "repo": repo]
        // A misconfigured dev build refuses before anything runs.
        guard (try? auth.configuration.buildSpace.check()) != nil,
              let answer = try? await client.daemon("owner.github_clone_token", args, timeout: CloudOwnerAPIClient.bound(.seconds(20))) else { return nil }
        return CloudGitHubCloneToken.parse(answer)
    }
}

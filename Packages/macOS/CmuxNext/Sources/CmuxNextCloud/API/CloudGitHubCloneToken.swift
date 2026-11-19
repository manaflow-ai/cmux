public import Foundation

/// A GitHub App token that lets git on this Mac clone one repository the cmux GitHub App reaches, for a
/// chat on this Mac started in a repository picked from the folder menu (``CloudGitHubPicker/cloneToken(repo:)``).
/// Asked of the same route a Cloud machine clones with (`POST /v1/integrations/github/token`), scoped to that
/// one repository and to reading its contents. The token is short-lived and goes only to that one `git clone`.
public nonisolated struct CloudGitHubCloneToken: Equatable, Sendable {
    /// The `ghs_…` installation token.
    public var token: String

    public init(token: String) { self.token = token }

    /// The ledger label Cloud shows for these tokens.
    static let label = "cmux-local-clone"
    /// What a clone needs: the repository's contents, read only.
    static let permissions: [String: String] = ["contents": "read", "metadata": "read"]

    /// The route's body for `repo` in `team`.
    static func body(team: String, repo: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["team": team, "repo": repo, "permissions": permissions, "label": label])
    }

    /// The route's answer `{token, repo, permissions}`: an installation token for `repo` with no more than
    /// ``permissions``; nil for anything else, so no other text reaches git.
    static func parse(status: Int, body: Data, repo: String) -> CloudGitHubCloneToken? {
        guard (200..<300).contains(status),
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let token = object["token"] as? String, isInstallationToken(token),
              let named = object["repo"] as? String, named.caseInsensitiveCompare(repo) == .orderedSame else { return nil }
        if let granted = object["permissions"] as? [String: Any] {
            for (name, level) in granted where !(permissions[name] == "read" && level as? String == "read") { return nil }
        }
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
              let team = MacInstallIdentity.team(ofToken: install),
              let body = CloudGitHubCloneToken.body(team: team, repo: repo) else { return nil }
        let base = auth.configuration.ownerAPIBaseURL().absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/v1/integrations/github/token") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(install)", forHTTPHeaderField: "Authorization")
        let prepared = request
        guard let answer = try? await withDeadline(.seconds(20), label: "POST /v1/integrations/github/token", {
            try await URLSession.shared.data(for: prepared)
        }), let http = answer.1 as? HTTPURLResponse else { return nil }
        return CloudGitHubCloneToken.parse(status: http.statusCode, body: answer.0, repo: repo)
    }
}

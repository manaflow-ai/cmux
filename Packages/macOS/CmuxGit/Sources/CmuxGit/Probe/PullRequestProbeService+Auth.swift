import Foundation

extension PullRequestProbeService {
    /// Resolves the API auth header: `GH_TOKEN`/`GITHUB_TOKEN` from the
    /// environment, else `gh auth token` via the injected runner. A `nil`
    /// result suppresses transport; GitHub probes never fall back to anonymous
    /// requests.
    nonisolated func authHeaderValue() async -> GitHubAuthHeaderLease? {
        return await authHeaderCache.header {
            if let environmentHeader = environmentAuthHeader() {
                return environmentHeader
            }
            return await ghAuthHeaderValue()
        }
    }

    private nonisolated func environmentAuthHeader() -> String? {
        guard let envToken = environment["GH_TOKEN"] ?? environment["GITHUB_TOKEN"] else {
            return nil
        }
        let trimmed = envToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "Bearer \(trimmed)"
    }

    private nonisolated func ghAuthHeaderValue() async -> String? {
        let directory = FileManager.default.currentDirectoryPath
        let token = await commandRunner.runStandardOutput(
            directory: directory,
            executable: "gh",
            arguments: ["auth", "token"],
            timeout: Self.authProbeTimeout
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { return nil }
        return "Bearer \(token)"
    }

    /// Drops a cached CLI credential after GitHub rejects an authenticated
    /// request. The next probe resolves a fresh credential.
    nonisolated func invalidateAuthHeader(_ lease: GitHubAuthHeaderLease) async {
        await authHeaderCache.invalidate(lease)
    }

    /// Applies auth-failure backoff after a replacement credential is rejected.
    nonisolated func recordAuthHeaderFailure(_ lease: GitHubAuthHeaderLease) async {
        await authHeaderCache.recordFailure(lease)
    }

    /// Clears an auth-failure streak after GitHub accepts the credential.
    nonisolated func recordAuthHeaderSuccess(_ lease: GitHubAuthHeaderLease) async {
        await authHeaderCache.recordSuccess(lease)
    }
}

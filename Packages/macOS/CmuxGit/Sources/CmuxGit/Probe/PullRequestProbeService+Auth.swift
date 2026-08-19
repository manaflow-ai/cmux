import Foundation

extension PullRequestProbeService {
    /// Resolves the API auth header: `GH_TOKEN`/`GITHUB_TOKEN` from the
    /// environment, else `gh auth token` via the injected runner. A `nil`
    /// result suppresses transport; GitHub probes never fall back to anonymous
    /// requests.
    nonisolated func authHeaderValue() async -> String? {
        if let envToken = environment["GH_TOKEN"] ?? environment["GITHUB_TOKEN"] {
            let trimmed = envToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return "Bearer \(trimmed)"
            }
        }

        return await authHeaderCache.header {
            await ghAuthHeaderValue()
        }
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
    nonisolated func invalidateAuthHeader(ifMatching header: String) async {
        await authHeaderCache.invalidate(ifMatching: header)
    }

    /// Applies auth-failure backoff after a replacement credential is rejected.
    nonisolated func recordAuthHeaderFailure(ifMatching header: String) async {
        await authHeaderCache.recordFailure(ifMatching: header)
    }
}

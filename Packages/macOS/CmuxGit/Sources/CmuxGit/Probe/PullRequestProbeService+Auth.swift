import Foundation

extension PullRequestProbeService {
    /// Resolves the API auth header: `GH_TOKEN`/`GITHUB_TOKEN` from the
    /// environment, else `gh auth token` via the injected runner, else `nil`
    /// (unauthenticated requests).
    nonisolated func authHeaderValue() async -> String? {
        let environment = ProcessInfo.processInfo.environment
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
            timeout: Self.probeTimeout
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { return nil }
        return "Bearer \(token)"
    }
}

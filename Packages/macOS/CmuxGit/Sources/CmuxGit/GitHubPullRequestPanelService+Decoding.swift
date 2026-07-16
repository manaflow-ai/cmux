import CmuxFoundation
import Foundation

extension GitHubPullRequestPanelService {
    nonisolated func decode<Value: Decodable>(_ output: String) throws -> Value {
        guard let data = output.data(using: .utf8) else {
            throw PullRequestPanelServiceError.invalidResponse
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            throw PullRequestPanelServiceError.invalidResponse
        }
    }

    nonisolated func requiredOutput(
        from result: CommandResult,
        failure: PullRequestPanelServiceError,
        allowsEmptyOutput: Bool = false
    ) throws -> String {
        guard result.executionError == nil,
              !result.timedOut,
              result.exitStatus == 0 else {
            throw classifiedFailure(result, fallback: failure)
        }
        let output = result.stdout ?? ""
        guard allowsEmptyOutput || !output.isEmpty else {
            throw PullRequestPanelServiceError.invalidResponse
        }
        return output
    }

    nonisolated func classifiedFailure(
        _ result: CommandResult,
        fallback: PullRequestPanelServiceError
    ) -> PullRequestPanelServiceError {
        let detail = [result.executionError, result.stderr]
            .compactMap { $0 }
            .joined(separator: "\n")
            .lowercased()
        let unavailableMarkers = [
            "not found", "no such file", "not logged into", "gh auth login",
            "authentication", "http 401", "bad credentials",
        ]
        if result.exitStatus == 127 || unavailableMarkers.contains(where: detail.contains) {
            return .githubCLIUnavailable
        }
        return fallback
    }

    nonisolated func isNoPullRequest(_ result: CommandResult) -> Bool {
        guard result.exitStatus != 0 else { return false }
        let detail = result.stderr?.lowercased() ?? ""
        return detail.contains("no pull requests found")
            || detail.contains("could not resolve to a pullrequest")
    }
}

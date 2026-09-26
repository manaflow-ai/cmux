import Foundation

/// Runs one fresh, read-only structured-output reviewer against a frozen candidate.
struct ReviewModelProcess {
    let executable: String
    let candidate: ReviewCandidate

    func response(role: String, schema: [String: Any], prompt: String) throws -> [String: Any] {
        let schemaURL = candidate.directory.appendingPathComponent("\(role).schema.json")
        let outputURL = candidate.directory.appendingPathComponent("\(role).json")
        try JSONSerialization.data(withJSONObject: schema).write(to: schemaURL, options: .atomic)
        // Fresh reviewers must not inherit the caller's socket, resume binding, or Git location.
        let removedKeys = ProcessInfo.processInfo.environment.keys.filter {
            $0.hasPrefix("CMUX_") || $0.hasPrefix("GIT_") || $0 == "CODEX_THREAD_ID"
        }.sorted()
        let environmentArguments = removedKeys.flatMap { ["-u", $0] } + ["CMUX_CODEX_HOOKS_DISABLED=1"]
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: environmentArguments + [
                executable, "--ask-for-approval", "never", "exec", "--sandbox", "read-only",
                "--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check",
                "--config", "project_doc_max_bytes=0",
                "--config", "default_tools_enabled=false", "--config", "tools={}",
                "--config", "mcp_servers={}", "--config", "web_search=false",
                "--config", "shell_environment_policy.inherit=none",
                "--cd", candidate.candidateDirectory.path,
                "--output-schema", schemaURL.path, "--output-last-message", outputURL.path,
                "-"
            ],
            stdinText: prompt,
            currentDirectoryPath: candidate.candidateDirectory.path,
            timeout: 900
        )
        guard result.status == 0, !result.timedOut else {
            throw CLIError(message: String.localizedStringWithFormat(
                CMUXDiffViewerLocalization.string("cli.review.error.reviewerFailed", defaultValue: "Review stage '%@' failed. Check that the reviewer is installed and signed in, then retry."),
                role
            ))
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576,
              let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: outputURL)) as? [String: Any] else {
            throw CLIError(message: CMUXDiffViewerLocalization.string("cli.review.error.invalidResponse", defaultValue: "The reviewer returned an invalid response."))
        }
        return payload
    }
}

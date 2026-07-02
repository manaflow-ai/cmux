import Foundation

// Git subprocess helpers for the diff CLI. Every git spawn goes through
// gitEnvArguments so GIT_OPTIONAL_LOCKS=0 (an env assignment consumed by
// /usr/bin/env) is never omitted: observing commands like `git diff`
// otherwise refresh the index under .git/index.lock and race the user's
// own git operations (#4779). Required locks (update-ref, stash create)
// are unaffected by the variable.
extension CMUXCLI {
    func gitSingleLine(_ arguments: [String], in directory: String) throws -> String {
        let output = try gitStdout(arguments, in: directory)
        guard let line = output
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !line.isEmpty else {
            throw CLIError(message: "git returned empty output for \(arguments.joined(separator: " "))")
        }
        return line
    }

    func gitEnvArguments(in directory: String, _ arguments: [String]) -> [String] {
        ["GIT_OPTIONAL_LOCKS=0", "git", "-C", directory] + arguments
    }

    func gitStdout(
        _ arguments: [String],
        in directory: String,
        timeout: TimeInterval = 60
    ) throws -> String {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: gitEnvArguments(in: directory, arguments),
            timeout: timeout
        )
        if result.timedOut {
            throw CLIError(message: "git \(arguments.joined(separator: " ")) timed out")
        }
        guard result.status == 0 else {
            let command = (["git"] + arguments).joined(separator: " ")
            throw CLIError(message: "\(command) failed with status \(result.status)")
        }
        return result.stdout
    }

    func gitDiffPatchArguments(_ tail: [String]) -> [String] {
        ["diff", "--no-ext-diff", "--no-color", "--binary"] + tail
    }

    func gitStdout(
        _ arguments: [String],
        in directory: String,
        timeout: TimeInterval = 60,
        allowedExitStatuses: Set<Int32>
    ) throws -> String {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: gitEnvArguments(in: directory, arguments),
            timeout: timeout
        )
        if result.timedOut {
            throw CLIError(message: "git \(arguments.joined(separator: " ")) timed out")
        }
        guard allowedExitStatuses.contains(result.status) else {
            let command = (["git"] + arguments).joined(separator: " ")
            throw CLIError(message: "\(command) failed with status \(result.status)")
        }
        return result.stdout
    }

    func gitStdoutData(
        _ arguments: [String],
        in directory: String,
        timeout: TimeInterval = 60,
        allowedExitStatuses: Set<Int32> = [0]
    ) throws -> Data {
        let result = CLIProcessRunner.runProcessData(
            executablePath: "/usr/bin/env",
            arguments: gitEnvArguments(in: directory, arguments),
            timeout: timeout
        )
        if result.timedOut {
            throw CLIError(message: "git \(arguments.joined(separator: " ")) timed out")
        }
        guard allowedExitStatuses.contains(result.status) else {
            let command = (["git"] + arguments).joined(separator: " ")
            throw CLIError(message: "\(command) failed with status \(result.status)")
        }
        return result.stdout
    }

    func gitUntrackedPaths(in repoRoot: String) throws -> [String] {
        let output = try gitStdout(["ls-files", "--others", "--exclude-standard", "-z"], in: repoRoot)
        return output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }
}

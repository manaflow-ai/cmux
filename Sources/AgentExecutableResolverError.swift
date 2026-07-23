import Foundation

enum AgentExecutableResolverError: LocalizedError, Equatable {
    case missing(displayName: String, executableName: String, searchedDirectories: [String])

    var message: String {
        switch self {
        case .missing(let displayName, let executableName, _):
            let format = String(
                localized: "agentSession.error.missingProviderExecutable",
                defaultValue: "%@ was not found. Install it and make sure \"%@\" is available on PATH."
            )
            let message = String(format: format, displayName, executableName)
            guard executableName == "claude" else { return message }
            // https://github.com/manaflow-ai/cmux/issues/7035: a `claude`
            // defined as a shell function/alias in the user's rc is invisible
            // to cmux; point at the setting that can reach it.
            let hint = String(
                localized: "agentSession.error.missingProviderExecutable.claudeShellFunctionHint",
                defaultValue:
                    "If claude is a shell function or alias in your shell profile, cmux cannot see it. Set Settings › Automation › Claude Binary Path to the real binary, or to a launch command containing \"$@\" to forward the arguments."
            )
            return message + " " + hint
        }
    }

    var errorDescription: String? {
        message
    }
}


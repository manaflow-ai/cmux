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
            return String(format: format, displayName, executableName)
        }
    }

    var errorDescription: String? {
        message
    }
}


import Foundation

/// Classifies process-observed working directories by their persistence authority.
struct AgentChatObservedWorkingDirectoryResolver {
    func resolve(
        environment: [String: String]?
    ) -> (path: String?, authority: AgentChatWorkingDirectoryAuthority) {
        guard let environment else { return (nil, .unknown) }
        if let value = environment["CMUX_AGENT_LAUNCH_CWD"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return (value, .processObservation)
        }
        if let value = environment["PWD"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return (value, .processObservation)
        }
        return (nil, .unknown)
    }
}

import Foundation

struct AgentProcessExecutableIdentityMatcher: Sendable {
    private struct Basename: Hashable, Sendable {
        let value: String

        init?(_ value: String) {
            let normalized = (value as NSString).lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalized.isEmpty else { return nil }
            self.value = normalized
        }
    }

    private let basenames: Set<Basename>

    init(policy: AgentProcessCandidatePolicy) {
        let registeredBasenames = policy.detectionRules.flatMap { rule in
            ([rule.processName].compactMap { $0 }
                + rule.processNames
                + rule.alternateProcessNames)
                .compactMap(Basename.init)
        }
        basenames = Set(registeredBasenames)
            .union(policy.builtInAgentBasenames.compactMap(Basename.init))
            .union(policy.wrapperBasenames.compactMap(Basename.init))
    }

    func matches(_ values: String?...) -> Bool {
        values
            .compactMap { $0 }
            .compactMap(Basename.init)
            .contains(where: basenames.contains)
    }
}

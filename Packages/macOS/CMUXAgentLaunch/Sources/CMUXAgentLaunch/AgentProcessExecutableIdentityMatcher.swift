import Foundation

struct AgentProcessExecutableIdentityMatcher: Sendable {
    private let basenames: Set<String>

    init(policy: AgentProcessCandidatePolicy) {
        let normalize: (String) -> String? = { value in
            let basename = (value as NSString).lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return basename.isEmpty ? nil : basename
        }
        let registeredBasenames = policy.detectionRules.flatMap { rule in
            ([rule.processName].compactMap { $0 }
                + rule.processNames
                + rule.alternateProcessNames)
                .compactMap(normalize)
        }
        basenames = Set(registeredBasenames)
            .union(policy.builtInAgentBasenames.compactMap(normalize))
            .union(policy.wrapperBasenames.compactMap(normalize))
    }

    func matches(_ values: String?...) -> Bool {
        values
            .compactMap { $0 }
            .compactMap { value in
                let basename = (value as NSString).lastPathComponent
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                return basename.isEmpty ? nil : basename
            }
            .contains(where: basenames.contains)
    }
}

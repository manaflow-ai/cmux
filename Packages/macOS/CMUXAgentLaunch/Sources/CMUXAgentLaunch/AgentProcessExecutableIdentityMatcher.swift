import Foundation

struct AgentProcessExecutableIdentityMatcher: Sendable {
    private let basenames: Set<String>

    init(policy: AgentProcessCandidatePolicy) {
        basenames = Self.registeredBasenames(in: policy.detectionRules)
            .union(policy.builtInAgentBasenames.compactMap(Self.normalizedBasename))
            .union(policy.wrapperBasenames.compactMap(Self.normalizedBasename))
    }

    func matches(_ values: String?...) -> Bool {
        values
            .compactMap { $0 }
            .compactMap(Self.normalizedBasename)
            .contains(where: basenames.contains)
    }

    private static func registeredBasenames(
        in rules: [AgentProcessDetectionRule]
    ) -> Set<String> {
        Set(rules.flatMap { rule in
            ([rule.processName].compactMap { $0 }
                + rule.processNames
                + rule.alternateProcessNames)
                .compactMap(Self.normalizedBasename)
        })
    }

    private static func normalizedBasename(_ value: String) -> String? {
        let basename = (value as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return basename.isEmpty ? nil : basename
    }
}

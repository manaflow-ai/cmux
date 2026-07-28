import CMUXAgentLaunch

extension AgentProcessCandidate {
    /// Projects an app-owned process snapshot into package-owned selection data.
    init(cmux process: CmuxTopProcessInfo) {
        self.init(
            processID: process.pid,
            name: process.name,
            path: process.path,
            isTerminalForegroundProcessGroup: process.isTerminalForegroundProcessGroup,
            shouldInspectArguments: CmuxTaskManagerCodingAgentDefinition.shouldReadArguments(
                processName: process.name,
                processPath: process.path
            )
        )
    }
}

extension AgentProcessDetectionRule {
    /// Projects an app-owned Vault detection rule into package-owned selection data.
    init(cmux rule: CmuxVaultAgentDetectRule) {
        self.init(
            processName: rule.processName,
            processNames: rule.processNames,
            argvContains: rule.argvContains,
            alternateProcessNames: rule.alternateProcessNames,
            alternateArgvContains: rule.alternateArgvContains,
            alternateArgvContainsAny: rule.alternateArgvContainsAny
        )
    }
}

extension AgentProcessCandidatePolicy {
    /// Projects the app-owned Vault registry and agent catalog into selection policy.
    init(cmux registry: CmuxVaultAgentRegistry) {
        self.init(
            usesBuiltInFastPath: registry.usesBuiltInProcessCandidateFastPath,
            detectionRules: registry.registrations.map {
                AgentProcessDetectionRule(cmux: $0.detect)
            },
            builtInAgentBasenames: Set(
                CmuxTaskManagerCodingAgentDefinition.builtIns
                    .flatMap(\.directBasenames)
            ).union([".opencode"]),
            wrapperBasenames: CmuxTaskManagerCodingAgentDefinition
                .argumentHostBasenames
                .union(["cmux"])
        )
    }
}

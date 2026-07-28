import Foundation

/// Chooses scoped processes whose arguments and environment can affect agent restore.
public struct AgentProcessCandidateSelector: Sendable {
    /// Process identifiers that should be fully decoded without raw metadata admission.
    public let processIDs: Set<Int>

    private let executableIdentityMatcher: AgentProcessExecutableIdentityMatcher
    private let launchExecutableMatcher: AgentLaunchExecutableMatcher
    private let normalizedArgumentNeedles: [[UInt8]]

    /// Creates a selector from app-owned process and registry projections.
    ///
    /// - Parameters:
    ///   - processes: Scoped processes that may represent agents.
    ///   - policy: The active detection and executable policy.
    ///   - launchExecutableMatcher: The launch-metadata trust policy.
    public init(
        processes: [AgentProcessCandidate],
        policy: AgentProcessCandidatePolicy,
        launchExecutableMatcher: AgentLaunchExecutableMatcher
    ) {
        let executableIdentityMatcher = AgentProcessExecutableIdentityMatcher(
            policy: policy
        )
        self.executableIdentityMatcher = executableIdentityMatcher
        self.launchExecutableMatcher = launchExecutableMatcher
        normalizedArgumentNeedles = unconstrainedArgumentNeedles(
            in: policy.detectionRules
        ).map {
            Array($0.replacingOccurrences(of: "\\", with: "/").lowercased().utf8)
        }
        guard policy.usesBuiltInFastPath else {
            processIDs = Set(processes.map(\.processID))
            return
        }

        processIDs = Set(processes.compactMap { process in
            isCandidate(
                process,
                executableIdentityMatcher: executableIdentityMatcher
            ) ? process.processID : nil
        })
    }

    /// Extracts all lightweight filter fields in one traversal of a raw buffer.
    ///
    /// - Parameter bytes: The complete bytes returned by `KERN_PROCARGS2`.
    /// - Returns: Lightweight filter metadata, or `nil` for a malformed buffer.
    public func rawMetadata(
        fromKernProcArgs bytes: [UInt8]
    ) -> AgentProcessFilterMetadata? {
        AgentProcessArgumentsParser().filterMetadata(
            fromKernProcArgs: bytes,
            normalizedArgumentNeedles: normalizedArgumentNeedles
        )
    }

    /// Decides whether raw metadata requires a full argument and environment decode.
    ///
    /// - Parameters:
    ///   - metadata: Lightweight metadata extracted from the process buffer.
    ///   - process: The process snapshot projection associated with the buffer.
    /// - Returns: `true` for an argument-needle match or a trusted cmux-recorded
    ///   Claude or Codex executable.
    public func rawMetadataMayRequireFullDecode(
        _ metadata: AgentProcessFilterMetadata,
        process: AgentProcessCandidate
    ) -> Bool {
        if metadata.argumentsContainAnyNeedle {
            return true
        }

        if executableIdentityMatcher.matches(metadata.executableArgument) {
            return true
        }

        let executableCandidates = [
            process.name,
            process.path,
            metadata.executableArgument,
            metadata.firstArgumentAfterExecutable,
        ].compactMap { $0 }
        return launchExecutableMatcher.matches(
            kind: "claude",
            executableCandidates: executableCandidates,
            recordedKind: metadata.agentLaunchKind,
            recordedExecutable: metadata.agentLaunchExecutable
        ) || launchExecutableMatcher.matches(
            kind: "codex",
            executableCandidates: executableCandidates,
            recordedKind: metadata.agentLaunchKind,
            recordedExecutable: metadata.agentLaunchExecutable
        )
    }
}

private func unconstrainedArgumentNeedles(
    in rules: [AgentProcessDetectionRule]
) -> [String] {
    rules.flatMap { rule in
        var needles: [String] = []
        if rule.processName == nil, rule.processNames.isEmpty {
            needles.append(contentsOf: rule.argvContains)
        }
        if rule.alternateProcessNames.isEmpty {
            needles.append(contentsOf: rule.alternateArgvContains)
            needles.append(contentsOf: rule.alternateArgvContainsAny)
        }
        return needles
    }
}

private func isCandidate(
    _ process: AgentProcessCandidate,
    executableIdentityMatcher: AgentProcessExecutableIdentityMatcher
) -> Bool {
    if process.isTerminalForegroundProcessGroup || process.shouldInspectArguments {
        return true
    }

    return executableIdentityMatcher.matches(process.name, process.path)
}

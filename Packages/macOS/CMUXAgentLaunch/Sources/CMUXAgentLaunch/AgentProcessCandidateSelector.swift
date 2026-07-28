import Foundation

/// Chooses scoped processes whose arguments and environment can affect agent restore.
public struct AgentProcessCandidateSelector: Sendable {
    /// Process identifiers that should be fully decoded without raw metadata admission.
    public let processIDs: Set<Int>

    private let normalizedArgumentNeedles: [[UInt8]]

    /// Creates a selector from app-owned process and registry projections.
    ///
    /// - Parameters:
    ///   - processes: Scoped processes that may represent agents.
    ///   - policy: The active detection and executable policy.
    public init(
        processes: [AgentProcessCandidate],
        policy: AgentProcessCandidatePolicy
    ) {
        normalizedArgumentNeedles = unconstrainedArgumentNeedles(
            in: policy.detectionRules
        ).map {
            Array($0.replacingOccurrences(of: "\\", with: "/").lowercased().utf8)
        }
        guard policy.usesBuiltInFastPath else {
            processIDs = Set(processes.map(\.processID))
            return
        }

        let registeredBasenames = registeredBasenames(
            in: policy.detectionRules
        )
        let builtInAgentBasenames = Set(
            policy.builtInAgentBasenames.compactMap(normalizedBasename)
        )
        let wrapperBasenames = Set(
            policy.wrapperBasenames.compactMap(normalizedBasename)
        )
        processIDs = Set(processes.compactMap { process in
            isCandidate(
                process,
                registeredBasenames: registeredBasenames,
                builtInAgentBasenames: builtInAgentBasenames,
                wrapperBasenames: wrapperBasenames
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

        let executableCandidates = [
            process.name,
            process.path,
            metadata.executableArgument,
            metadata.firstArgumentAfterExecutable,
        ].compactMap { $0 }
        return agentLaunchExecutableMatches(
            kind: "claude",
            executableCandidates: executableCandidates,
            recordedKind: metadata.agentLaunchKind,
            recordedExecutable: metadata.agentLaunchExecutable
        ) || agentLaunchExecutableMatches(
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

private func registeredBasenames(
    in rules: [AgentProcessDetectionRule]
) -> Set<String> {
    Set(rules.flatMap { rule in
        ([rule.processName].compactMap { $0 }
            + rule.processNames
            + rule.alternateProcessNames)
            .compactMap(normalizedBasename)
    })
}

private func isCandidate(
    _ process: AgentProcessCandidate,
    registeredBasenames: Set<String>,
    builtInAgentBasenames: Set<String>,
    wrapperBasenames: Set<String>
) -> Bool {
    if process.isTerminalForegroundProcessGroup || process.shouldInspectArguments {
        return true
    }

    let basenames = [process.name, process.path]
        .compactMap { $0 }
        .compactMap(normalizedBasename)
    return basenames.contains { basename in
        registeredBasenames.contains(basename)
            || builtInAgentBasenames.contains(basename)
            || wrapperBasenames.contains(basename)
    }
}

private func normalizedBasename(_ value: String) -> String? {
    let basename = (value as NSString).lastPathComponent
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    return basename.isEmpty ? nil : basename
}

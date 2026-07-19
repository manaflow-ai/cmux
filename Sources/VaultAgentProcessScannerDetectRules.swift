import CMUXAgentLaunch
import Foundation

private let knownVaultProcessRestoreKinds = Set(RestorableAgentKind.allCases.map(\.rawValue))
    .union(RestorableAgentKind.registryOwnedRawValues)

extension CmuxVaultAgentRegistration {
    func processDetectedSnapshotIsRestorable(for process: VaultObservedAgentProcess) -> Bool {
        Self.processDetectedSnapshotIsRestorable(kind: id, for: process)
    }

    static func processDetectedSnapshotIsRestorable(
        kind rawKind: String,
        for process: VaultObservedAgentProcess
    ) -> Bool {
        let kind = rawKind.lowercased()
        if kind == "campfire",
           process.environment["CAMPFIRE_SESSION_ROLE"] != "host" {
            return false
        }
        guard knownVaultProcessRestoreKinds.contains(kind) else { return true }

        let capturedArguments = Self.decodedCapturedArguments(
            process.environment["CMUX_AGENT_LAUNCH_ARGV_B64"]
        )
        let capturedKind = process.environment["CMUX_AGENT_LAUNCH_KIND"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let capturedExecutable = process.environment["CMUX_AGENT_LAUNCH_EXECUTABLE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trustedCapture = capturedArguments.flatMap { arguments -> [String]? in
            AgentLaunchCaptureTrust.capturedArgumentsDescribeKind(
                launcher: capturedKind,
                executablePath: capturedExecutable,
                arguments: arguments,
                kind: kind
            ) ? arguments : nil
        }
        let liveProcessName = process.processPath ?? process.processName
        let classifier = AgentLaunchModeClassifier()
        let liveMode = classifier.processMode(
            processName: liveProcessName,
            arguments: process.arguments,
            kind: kind
        )
        let interpreterNames: Set<String> = [
            "node", "nodejs", "bun", "deno", "tsx", "ts-node", "ts_node",
        ]
        let observedIsInterpreterHost = process.executableBasenames.contains {
            interpreterNames.contains($0.lowercased())
        }
        let canUseCapturedInterpreterLaunch = ["pi", "omp", "campfire"].contains(kind)
            && observedIsInterpreterHost
            && liveMode == .unknown
        let mode: AgentProcessLaunchMode
        if canUseCapturedInterpreterLaunch, let trustedCapture {
            mode = classifier.processMode(
                processName: capturedExecutable?.isEmpty == false
                    ? capturedExecutable
                    : trustedCapture.first,
                arguments: trustedCapture,
                kind: kind
            )
        } else {
            mode = liveMode
        }
        switch mode {
        case .oneShot, .nonSession:
            return false
        case .interactive, .unknown:
            return true
        }
    }

    private static func decodedCapturedArguments(_ rawValue: String?) -> [String]? {
        let maximumEncodedBytes = 1_400_000
        let maximumArgumentCount = 4_096
        guard let rawValue,
              rawValue.utf8.count <= maximumEncodedBytes,
              let data = Data(base64Encoded: rawValue) else {
            return nil
        }
        var arguments: [String] = []
        var start = data.startIndex
        for index in data.indices where data[index] == 0 {
            guard arguments.count < maximumArgumentCount else { return nil }
            guard index > start,
                  let argument = String(data: data[start..<index], encoding: .utf8),
                  !argument.isEmpty else {
                start = data.index(after: index)
                continue
            }
            arguments.append(argument)
            start = data.index(after: index)
        }
        if start < data.endIndex {
            guard arguments.count < maximumArgumentCount,
                  let argument = String(data: data[start..<data.endIndex], encoding: .utf8),
                  !argument.isEmpty else {
                return nil
            }
            arguments.append(argument)
        }
        return arguments.isEmpty ? nil : arguments
    }
}

extension CmuxVaultAgentDetectRule {
    var detectionIndexProcessNames: [String] {
        var names: [String] = []
        let primaryNames = primaryProcessNames
        if !primaryNames.isEmpty || !argvContains.isEmpty {
            names.append(contentsOf: primaryNames)
        }
        if !alternateArgvContains.isEmpty || !alternateArgvContainsAny.isEmpty {
            names.append(contentsOf: alternateProcessNames)
        }
        return names
    }

    var needsUnindexedDetectionFallback: Bool {
        let primaryNames = primaryProcessNames
        let primaryNeedsFallback = primaryNames.isEmpty && !argvContains.isEmpty
        let hasAlternateCriteria = !alternateArgvContains.isEmpty
            || !alternateArgvContainsAny.isEmpty
        let alternateNeedsFallback = hasAlternateCriteria && alternateProcessNames.isEmpty
        return primaryNeedsFallback || alternateNeedsFallback
    }

    func matches(_ process: VaultObservedAgentProcess) -> Bool {
        let expectedNames = primaryProcessNames
        let hasPrimaryCriteria = !expectedNames.isEmpty || !argvContains.isEmpty
        let hasAlternateCriteria = !alternateArgvContains.isEmpty || !alternateArgvContainsAny.isEmpty
        guard hasPrimaryCriteria || hasAlternateCriteria else { return false }
        let primary = hasPrimaryCriteria && primaryMatches(process, expectedNames: expectedNames)
        return primary || alternateMatches(process)
    }

    func usesAlternateMatchWithoutPrimaryMatch(_ process: VaultObservedAgentProcess) -> Bool {
        let expectedNames = primaryProcessNames
        let hasPrimaryCriteria = !expectedNames.isEmpty || !argvContains.isEmpty
        return alternateMatches(process)
            && !(hasPrimaryCriteria && primaryMatches(process, expectedNames: expectedNames))
    }

    func alternateLaunchArguments(for process: VaultObservedAgentProcess, defaultExecutable: String) -> [String] {
        guard !process.arguments.isEmpty else { return [defaultExecutable] }
        if let entrypointIndex = alternateEntrypointIndex(in: process.arguments) {
            return [defaultExecutable] + Array(process.arguments.dropFirst(entrypointIndex + 1))
        }
        return [defaultExecutable] + Array(process.arguments.dropFirst())
    }

    private var primaryProcessNames: [String] {
        var expectedNames = processNames
        if let processName { expectedNames.append(processName) }
        return expectedNames
    }

    private func primaryMatches(
        _ process: VaultObservedAgentProcess,
        expectedNames: [String]
    ) -> Bool {
        let processNameMatch = expectedNames.isEmpty || expectedNames.contains { expected in
            process.executableBasenames.contains { candidate in
                candidate.compare(expected, options: [.caseInsensitive, .literal]) == .orderedSame
            }
        }
        return processNameMatch && (argvContains.isEmpty || process.argumentsContainAll(argvContains))
    }

    private func alternateMatches(_ process: VaultObservedAgentProcess) -> Bool {
        let alternateProcessNameMatch = alternateProcessNames.isEmpty || alternateProcessNames.contains { expected in
            process.executableBasenames.contains { candidate in
                candidate.compare(expected, options: [.caseInsensitive, .literal]) == .orderedSame
            }
        }
        let allNeedlesMatch = !alternateArgvContains.isEmpty
            && alternateProcessNameMatch
            && process.argumentsContainAll(alternateArgvContains)
        let anyNeedleMatches = !alternateArgvContainsAny.isEmpty
            && alternateProcessNameMatch
            && process.argumentsContainAny(alternateArgvContainsAny)
        return allNeedlesMatch || anyNeedleMatches
    }

    private func alternateEntrypointIndex(in arguments: [String]) -> Int? {
        let needles = alternateArgvContains + alternateArgvContainsAny
        return arguments.indices.first { index in
            needles.contains { argument(arguments[index], containsNeedle: $0) }
        }
    }

    private func argument(_ argument: String, containsNeedle needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        if needle.contains("/") {
            let normalizedArgument = argument.replacingOccurrences(of: "\\", with: "/")
            let normalizedNeedle = needle.replacingOccurrences(of: "\\", with: "/")
            return normalizedArgument.range(
                of: normalizedNeedle,
                options: [.caseInsensitive, .literal]
            ) != nil
        }
        return argument.range(of: needle, options: [.caseInsensitive, .literal]) != nil
            || (argument as NSString).lastPathComponent.range(
                of: needle,
                options: [.caseInsensitive, .literal]
            ) != nil
    }
}

extension VaultObservedAgentProcess {
    func argumentsContainAny(_ needles: [String]) -> Bool {
        needles.contains { needle in
            argumentsContainAll([needle])
        }
    }
}

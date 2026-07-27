import Foundation

extension CmuxVaultAgentRegistration {
    func processDetectedSnapshotIsRestorable(for process: VaultObservedAgentProcess) -> Bool {
        guard id == "campfire" else { return true }
        return process.environment["CAMPFIRE_SESSION_ROLE"] == "host"
    }
}

extension CmuxVaultAgentDetectRule {
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

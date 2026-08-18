import Foundation
import CmuxCore

extension CmuxVaultAgentRegistration {
    func processDetectedSnapshotIsRestorable(for process: VaultObservedAgentProcess) -> Bool {
        switch id {
        case "campfire":
            return process.environment["CAMPFIRE_SESSION_ROLE"] == "host"
        case "hermes-agent":
            return process.isInteractiveHermesAgentInvocation
        default:
            return true
        }
    }

    func processDetectedSnapshotIsRestorable(
        for process: VaultObservedAgentProcess,
        manifest: CmuxAgentDetectionManifest?
    ) -> Bool {
        if let condition = manifest?.restorableWhen {
            return condition.environmentEquals.allSatisfy { key, value in
                process.environment[key] == value
            }
        }
        return processDetectedSnapshotIsRestorable(for: process)
    }
}

extension CmuxVaultAgentDetectRule {
    func matches(_ process: VaultObservedAgentProcess) -> Bool {
        let expectedNames = primaryProcessNames
        let hasPrimaryCriteria = !expectedNames.isEmpty || !argvContains.isEmpty
        let hasAlternateCriteria = !alternateArgvContains.isEmpty
            || !alternateArgvContainsAny.isEmpty
            || !alternateArgvBasenamesAny.isEmpty
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
        if let entrypointIndex = alternateEntrypointIndex(in: process) {
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
        let alternateProcessNameMatch = alternateProcessNames.isEmpty
            || alternateProcessNames.contains { expected in
                process.executableBasenames.contains { candidate in
                    processBasename(candidate, matches: expected)
                }
            }
        let allNeedlesMatch = !alternateArgvContains.isEmpty
            && alternateProcessNameMatch
            && process.argumentsContainAll(alternateArgvContains)
        let anyNeedleMatches = !alternateArgvContainsAny.isEmpty
            && alternateProcessNameMatch
            && process.argumentsContainAny(alternateArgvContainsAny)
        let anyBasenameMatches = !alternateArgvBasenamesAny.isEmpty
            && alternateProcessNameMatch
            && alternateBasenameEntrypointIndex(in: process) != nil
        return allNeedlesMatch || anyNeedleMatches || anyBasenameMatches
    }

    private func alternateEntrypointIndex(in process: VaultObservedAgentProcess) -> Int? {
        if let basenameIndex = alternateBasenameEntrypointIndex(in: process) {
            return basenameIndex
        }
        let arguments = process.arguments
        let needles = alternateArgvContains + alternateArgvContainsAny
        return arguments.indices.first { index in
            needles.contains { argument(arguments[index], containsNeedle: $0) }
        }
    }

    private func alternateBasenameEntrypointIndex(in process: VaultObservedAgentProcess) -> Int? {
        guard !alternateArgvBasenamesAny.isEmpty else { return nil }
        let arguments = process.arguments
        guard !arguments.isEmpty else { return nil }

        if process.executableBasenames.contains(where: isPythonRuntimeBasename) {
            guard let index = pythonEntrypointIndex(in: arguments),
                  argument(arguments[index], hasBasenameIn: alternateArgvBasenamesAny) else {
                return nil
            }
            return index
        }

        return arguments.indices.first { index in
            argument(arguments[index], hasBasenameIn: alternateArgvBasenamesAny)
        }
    }

    private func pythonEntrypointIndex(in arguments: [String]) -> Int? {
        var index = arguments.startIndex
        if index < arguments.endIndex,
           isPythonRuntimeBasename((arguments[index] as NSString).lastPathComponent) {
            index = arguments.index(after: index)
        }

        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--" {
                let nextIndex = arguments.index(after: index)
                return nextIndex < arguments.endIndex ? nextIndex : nil
            }
            if argument == "-" {
                return nil
            }
            if argument == "-m" {
                let moduleIndex = arguments.index(after: index)
                return moduleIndex < arguments.endIndex ? moduleIndex : nil
            }
            if pythonOptionRunsWithoutScript(argument) {
                return nil
            }
            if argument.hasPrefix("-") {
                index += 1 + pythonOptionValueCount(argument)
                continue
            }
            return index
        }
        return nil
    }

    private func isPythonRuntimeBasename(_ basename: String) -> Bool {
        let normalized = basename.lowercased()
        if normalized == "python" || normalized == "python3" {
            return true
        }
        guard normalized.hasPrefix("python3.") else { return false }
        let suffix = normalized.dropFirst("python3.".count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    private func processBasename(_ candidate: String, matches expected: String) -> Bool {
        if isPythonRuntimeBasename(expected) {
            return isPythonRuntimeBasename(candidate)
        }
        return candidate.compare(
            expected,
            options: [.caseInsensitive, .literal]
        ) == .orderedSame
    }

    private func pythonOptionRunsWithoutScript(_ argument: String) -> Bool {
        let option = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
        switch option {
        case "-c", "-h", "--help", "-V", "--version":
            return true
        default:
            return false
        }
    }

    private func pythonOptionValueCount(_ argument: String) -> Int {
        guard !argument.contains("=") else { return 0 }
        if ["-W", "-X", "--check-hash-based-pycs"].contains(argument) {
            return 1
        }
        guard argument.hasPrefix("-"), !argument.hasPrefix("--"),
              let last = argument.last else {
            return 0
        }
        return last == "W" || last == "X" ? 1 : 0
    }

    private func argument(_ argument: String, hasBasenameIn expectedBasenames: [String]) -> Bool {
        guard !expectedBasenames.isEmpty else { return false }
        let normalizedArgument = argument.replacingOccurrences(of: "\\", with: "/")
        let basename = (normalizedArgument as NSString).lastPathComponent
        return expectedBasenames.contains { expected in
            basename.compare(expected, options: [.caseInsensitive, .literal]) == .orderedSame
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

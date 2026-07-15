import Foundation

struct VaultAgentProcessCandidateSelector {
    let processIDs: Set<Int>
    private let unconstrainedArgumentNeedles: [[UInt8]]

    init(
        processes: [CmuxTopProcessInfo],
        registry: CmuxVaultAgentRegistry
    ) {
        unconstrainedArgumentNeedles = Self.unconstrainedArgumentNeedles(in: registry).map {
            Array($0.replacingOccurrences(of: "\\", with: "/").lowercased().utf8)
        }
        guard Self.canUseBuiltInFastPath(registry: registry) else {
            processIDs = Set(processes.map(\.pid))
            return
        }

        let registeredBasenames = Self.registeredBasenames(in: registry)
        processIDs = Set(processes.compactMap { process in
            Self.isCandidate(process, registeredBasenames: registeredBasenames)
                ? process.pid
                : nil
        })
    }

    func contains(_ processID: Int) -> Bool {
        processIDs.contains(processID)
    }

    func rawArgumentsMayMatchUnconstrainedRule(_ bytes: [UInt8]) -> Bool {
        CmuxTopProcessSnapshot.processArgumentsContainAnyNeedle(
            fromKernProcArgs: bytes,
            normalizedNeedles: unconstrainedArgumentNeedles
        )
    }

    private static func unconstrainedArgumentNeedles(
        in registry: CmuxVaultAgentRegistry
    ) -> [String] {
        registry.registrations.flatMap { registration in
            let rule = registration.detect
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

    private static func canUseBuiltInFastPath(registry: CmuxVaultAgentRegistry) -> Bool {
        let builtInsByID = Dictionary(
            uniqueKeysWithValues: builtInRegistrations.map { ($0.id, $0) }
        )
        return registry.registrations.allSatisfy { registration in
            builtInsByID[registration.id] == registration
        }
    }

    private static func registeredBasenames(in registry: CmuxVaultAgentRegistry) -> Set<String> {
        Set(registry.registrations.flatMap { registration in
            let rule = registration.detect
            return ([rule.processName].compactMap { $0 }
                + rule.processNames
                + rule.alternateProcessNames)
                .compactMap(normalizedBasename)
        })
    }

    private static func isCandidate(
        _ process: CmuxTopProcessInfo,
        registeredBasenames: Set<String>
    ) -> Bool {
        if process.isTerminalForegroundProcessGroup {
            return true
        }
        if CmuxTaskManagerCodingAgentDefinition.shouldReadArguments(
            processName: process.name,
            processPath: process.path
        ) {
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

    private static func normalizedBasename(_ value: String) -> String? {
        let basename = (value as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return basename.isEmpty ? nil : basename
    }

    private static let builtInRegistrations: [CmuxVaultAgentRegistration] = [
        .builtInPi,
        .builtInOmp,
        .builtInCampfire,
        .builtInAntigravity,
        .builtInGrok,
    ]

    private static let builtInAgentBasenames = Set(
        CmuxTaskManagerCodingAgentDefinition.builtIns
            .flatMap(\.directBasenames)
            .compactMap(normalizedBasename)
    ).union([".opencode"])

    private static let wrapperBasenames: Set<String> = ["cmux"]
}

import Foundation

nonisolated func cmuxTopCanonicalProcessName(name: String, path: String?) -> String {
    guard name.count == 15 || name.count == 16 else { return name }
    guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return name }
    let basename = (path as NSString).lastPathComponent
    guard basename.count > name.count else { return name }
    guard basename.lowercased().hasPrefix(name.lowercased()) else { return name }
    return basename
}

nonisolated extension CmuxTopProcessSnapshot {
    func codingAgentDefinitionsByPID(
        for pids: some Sequence<Int>
    ) -> [Int: CmuxTaskManagerCodingAgentDefinition] {
        var definitions: [Int: CmuxTaskManagerCodingAgentDefinition] = [:]
        for pid in pids {
            guard let process = processesByPID[pid] else { continue }
            let processArguments = Self.processArgumentsIfNeeded(for: process)
            guard let definition = CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: process.name,
                processPath: process.path,
                arguments: processArguments?.arguments ?? [],
                environment: processArguments?.environment ?? [:]
            ) else { continue }
            definitions[pid] = definition
        }
        return definitions
    }
}

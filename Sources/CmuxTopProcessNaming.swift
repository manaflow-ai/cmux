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
    static func processArgumentsIfNeeded(for process: CmuxTopProcessInfo) -> CmuxTopProcessArguments? {
        guard CmuxTaskManagerCodingAgentDefinition.shouldReadArguments(
            processName: process.name,
            processPath: process.path
        ) else { return nil }
        return processArgumentsAndEnvironment(for: process.pid)
    }

    /// Memoized per snapshot: each PID is classified at most once, so program totals,
    /// coding-agent totals, and memory diagnostics always agree even if a process
    /// exits (or KERN_PROCARGS2 stops answering) between payload sections, and the
    /// live argument read runs at most once per PID per snapshot.
    func codingAgentDefinitionsByPID(
        for pids: some Sequence<Int>
    ) -> [Int: CmuxTaskManagerCodingAgentDefinition] {
        var definitions: [Int: CmuxTaskManagerCodingAgentDefinition] = [:]
        codingAgentDefinitionCacheLock.lock()
        defer { codingAgentDefinitionCacheLock.unlock() }
        for pid in pids {
            let definition: CmuxTaskManagerCodingAgentDefinition?
            if let cached = codingAgentDefinitionCache[pid] {
                definition = cached
            } else {
                definition = classifyCodingAgent(pid: pid)
                // updateValue stores .some(nil) for unclassified PIDs; plain subscript
                // assignment of a nil optional would remove the entry instead.
                codingAgentDefinitionCache.updateValue(definition, forKey: pid)
            }
            if let definition {
                definitions[pid] = definition
            }
        }
        return definitions
    }

    private func classifyCodingAgent(pid: Int) -> CmuxTaskManagerCodingAgentDefinition? {
        guard let process = processesByPID[pid] else { return nil }
        let processArguments = Self.processArgumentsIfNeeded(for: process)
        return CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: process.name,
            processPath: process.path,
            arguments: processArguments?.arguments ?? [],
            environment: processArguments?.environment ?? [:]
        )
    }
}

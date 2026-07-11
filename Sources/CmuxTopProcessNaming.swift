import Foundation

nonisolated func cmuxTopCanonicalProcessName(name: String, path: String?) -> String {
    guard name.count == 15 || name.count == 16 else { return name }
    guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return name }
    let basename = (path as NSString).lastPathComponent
    guard basename.count > name.count else { return name }
    guard basename.lowercased().hasPrefix(name.lowercased()) else { return name }
    return basename
}

/// Lock-guarded per-PID memo for coding-agent classification. The mutable cache is
/// private so no caller can touch it without going through the guarded accessor,
/// which preserves the snapshot's `@unchecked Sendable` safety argument.
/// A lock (not an actor) is deliberate: every consumer is a synchronous
/// `nonisolated` payload builder on the snapshot, so actor isolation would force
/// `await` through the synchronous socket payload pipeline.
nonisolated final class CmuxTopCodingAgentDefinitionMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [Int: CmuxTaskManagerCodingAgentDefinition?] = [:]

    func definitions(
        for pids: some Sequence<Int>,
        classify: (Int) -> CmuxTaskManagerCodingAgentDefinition?
    ) -> [Int: CmuxTaskManagerCodingAgentDefinition] {
        var definitions: [Int: CmuxTaskManagerCodingAgentDefinition] = [:]
        lock.lock()
        defer { lock.unlock() }
        for pid in pids {
            let definition: CmuxTaskManagerCodingAgentDefinition?
            if let cached = cache[pid] {
                definition = cached
            } else {
                definition = classify(pid)
                // updateValue stores .some(nil) for unclassified PIDs; plain subscript
                // assignment of a nil optional would remove the entry instead.
                cache.updateValue(definition, forKey: pid)
            }
            if let definition {
                definitions[pid] = definition
            }
        }
        return definitions
    }
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
        codingAgentDefinitionMemo.definitions(for: pids) { pid in
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
}

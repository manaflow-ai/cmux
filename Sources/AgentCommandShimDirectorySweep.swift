import CmuxFoundation
import CmuxTerminal
import Darwin
import Foundation

/// Removes per-surface command shim directories whose pane is gone.
///
/// A pane removes its own directory when it closes. This collects what that
/// misses: panes that went with a crash or a forced quit, and the directories
/// builds before the close-time removal left behind. It runs once per launch,
/// off the main actor.
///
/// Stable, nightly and tagged builds share one shim root. A directory stays
/// while the cmux that installed it runs, or while some process still names
/// it; see ``TerminalSurfaceAgentCommandShimCleanup`` for the rules.
///
/// ```swift
/// Task.detached(priority: .utility) {
///     AgentCommandShimDirectorySweep.sweep()
/// }
/// ```
enum AgentCommandShimDirectorySweep {
    /// How long a directory nobody owns is kept after its last write.
    static let unusedLifetime: TimeInterval = 24 * 60 * 60

    /// Removes the unused shim directories under `rootDirectory`.
    ///
    /// - Parameters:
    ///   - rootDirectory: The durable shim root.
    ///   - now: The current date.
    /// - Returns: The names of the directories removed.
    @discardableResult
    nonisolated static func sweep(
        rootDirectory: URL = TerminalSurfaceRuntimeFilesystem.liveAgentCommandShimRootDirectory(),
        now: Date = Date()
    ) -> [String] {
        let listing = DarwinProcessEnumerator().capture()
        let user = getuid()
        let currentProcessID = Int(getpid())
        let processes = listing.processes.filter { $0.pbi_uid == user }
        // Without a reading of what processes still name, any directory might
        // be one of them.
        guard let inUseDirectoryNames = TerminalSurfaceAgentCommandShimCleanup.shimDirectoryNamesInUse(
            byProcesses: processes.lazy.map { Int($0.pbi_pid) },
            processListIsComplete: !listing.isTruncated,
            currentProcessID: currentProcessID,
            environmentValues: { processID in
                CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: processID)
                    .map { Array($0.environment.values) }
            }
        ) else {
#if DEBUG
            cmuxDebugLog("shims.sweep skipped reason=processTableUnreadable")
#endif
            return []
        }
        // A directory without an owner record may belong to an open pane of
        // a cmux that predates the records.
        let anotherCmuxIsRunning = TerminalSurfaceAgentCommandShimCleanup.anotherCmuxIsRunning(
            amongProcesses: processes.lazy
                .filter { Int($0.pbi_pid) != currentProcessID }
                .map { process in
                    (
                        name: CmuxTopProcessSnapshot.fixedString(process.pbi_name),
                        executablePath: CmuxTopProcessSnapshot.processPath(pid: Int(process.pbi_pid))
                    )
                }
        )
        let removed = TerminalSurfaceAgentCommandShimCleanup.removeUnusedShimDirectories(
            rootDirectory: rootDirectory,
            inUseDirectoryNames: inUseDirectoryNames,
            unusedSince: now.addingTimeInterval(-unusedLifetime),
            removesDirectoriesWithoutOwnerRecord: !anotherCmuxIsRunning
        )
#if DEBUG
        cmuxDebugLog(
            "shims.sweep removed=\(removed.count) named=\(inUseDirectoryNames.count) " +
            "anotherCmux=\(anotherCmuxIsRunning ? 1 : 0)"
        )
#endif
        return removed
    }
}

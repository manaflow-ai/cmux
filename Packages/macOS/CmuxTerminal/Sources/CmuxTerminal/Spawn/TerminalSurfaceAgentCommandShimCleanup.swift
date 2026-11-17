public import Foundation
public import CmuxFoundation

/// Removes per-surface agent command shim directories nothing can use any more.
public enum TerminalSurfaceAgentCommandShimCleanup {
    @discardableResult
    public static func removeShimDirectory(
        surfaceId: UUID,
        rootDirectory: URL,
        owner: AgentPIDProcessIdentity? = AgentPIDProcessIdentity(pid: getpid()),
        ownerIsRunning: (AgentPIDProcessIdentity) -> Bool = { AgentPIDProcessIdentity(pid: $0.pid) == $0 },
        fileManager: FileManager = .default
    ) -> Bool {
        false
    }

    @discardableResult
    public static func writeOwnerRecord(
        inDirectory directory: URL,
        owner: AgentPIDProcessIdentity? = AgentPIDProcessIdentity(pid: getpid())
    ) -> Bool {
        false
    }

    public static func ownerRecords(
        inDirectory directory: URL,
        fileManager: FileManager = .default
    ) -> [AgentPIDProcessIdentity] {
        []
    }

    public static func shimDirectoryNames(
        inEnvironmentValues values: some Sequence<String>
    ) -> Set<String> {
        []
    }

    public static func shimDirectoryNamesInUse(
        byProcesses processIDs: some Sequence<Int>,
        processListIsComplete: Bool,
        currentProcessID: Int,
        environmentValues: (_ processID: Int) -> [String]?
    ) -> Set<String>? {
        nil
    }

    public static func anotherCmuxIsRunning(
        amongProcesses processes: some Sequence<(name: String, executablePath: String?)>,
        fileExists: (_ path: String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        false
    }

    public final class DirectoryLock {
        public init?(shimParentDirectory: URL, waitingUpTo patience: Duration = .zero) {
        }
    }

    @discardableResult
    public static func removeUnusedShimDirectories(
        rootDirectory: URL,
        inUseDirectoryNames: Set<String>,
        unusedSince cutoff: Date,
        removesDirectoriesWithoutOwnerRecord: Bool,
        ownerIsRunning: (AgentPIDProcessIdentity) -> Bool = { AgentPIDProcessIdentity(pid: $0.pid) == $0 },
        fileManager: FileManager = .default
    ) -> [String] {
        []
    }
}

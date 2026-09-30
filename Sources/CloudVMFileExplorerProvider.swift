import Foundation

/// An immutable Cloud filesystem identity with I/O owned by its service actor.
final class CloudVMFileExplorerProvider: RemoteFileExplorerProvider, Sendable {
    let id: UUID
    let target: CloudFileExplorerTarget?
    let vmID: String
    let displayTarget: String
    let homePath: String
    let isAvailable: Bool
    private let service: CloudFileExplorerService

    nonisolated var remoteIdentity: String {
        guard let target else { return "cloud-provider:\(id.uuidString)" }
        let remoteWorkspace = target.identity.remoteWorkspaceID ?? ""
        return "cloud:\(target.identity.workspaceID.uuidString):\(target.identity.vmID):\(remoteWorkspace):\(target.identity.team.teamID):\(target.identity.team.generation)"
    }

    /// Creates a provider for one Cloud machine.
    init(
        vmID: String,
        displayTarget: String,
        homePath: String = "",
        isAvailable: Bool,
        target: CloudFileExplorerTarget? = nil,
        commandRunner: (any CloudFileExplorerCommandRunning)? = nil,
        fileRPC: (any CloudWorkspaceFileRPC)? = nil
    ) {
        self.id = UUID()
        self.target = target
        self.vmID = vmID
        self.displayTarget = displayTarget
        self.homePath = homePath
        self.isAvailable = isAvailable
        // Production uses the machine's direct daemon channel; an injected command
        // runner (tests) exercises the exec path unless a channel is injected too.
        self.service = CloudFileExplorerService(
            commandRunner: commandRunner ?? LiveCloudFileExplorerCommandRunner(target: target),
            fileRPC: fileRPC ?? (commandRunner == nil ? LiveCloudWorkspaceFileRPC(target: target) : nil)
        )
    }

    private init(provider: CloudVMFileExplorerProvider, homePath: String) {
        id = provider.id
        target = provider.target
        vmID = provider.vmID
        displayTarget = provider.displayTarget
        self.homePath = homePath
        isAvailable = provider.isAvailable
        service = provider.service
    }

    /// Returns an equivalent provider with a resolved home path.
    func resolvingHome(_ path: String) -> CloudVMFileExplorerProvider {
        CloudVMFileExplorerProvider(provider: self, homePath: path)
    }

    /// Resolves the machine home through the service actor.
    nonisolated func resolveHomePath() async throws -> String {
        guard isAvailable else { throw FileExplorerError.providerUnavailable }
        return try await service.resolveHome(vmID: vmID)
    }

    /// Lists a directory on the Cloud machine.
    nonisolated func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        guard isAvailable else { throw FileExplorerError.providerUnavailable }
        return try await service.listDirectory(vmID: vmID, path: path, showHidden: showHidden)
    }

    nonisolated func search(query: String, rootPath: String) async throws -> FileSearchSnapshot {
        guard isAvailable else { throw FileExplorerError.providerUnavailable }
        return try await service.search(vmID: vmID, query: query, rootPath: rootPath)
    }

    /// Git status of the repository containing `directory`, as porcelain v1 `-z` text.
    nonisolated func gitStatus(directory: String) async throws -> (repositoryRoot: String, porcelain: String)? {
        guard isAvailable else { throw FileExplorerError.providerUnavailable }
        return try await service.gitStatus(vmID: vmID, directory: directory)
    }

    /// Unified patch of the repository containing `directory`.
    nonisolated func diff(directory: String, staged: Bool) async throws -> (repositoryRoot: String, patch: Data)? {
        guard isAvailable else { throw FileExplorerError.providerUnavailable }
        return try await service.diff(vmID: vmID, directory: directory, staged: staged)
    }

    /// Streams sets of changed directories among `directories` until cancelled or the
    /// channel fails. Finishes at once when the machine's daemon cannot watch.
    nonisolated func directoryChanges(_ directories: [String]) -> AsyncThrowingStream<[String], Error> {
        let service = service, vmID = vmID, available = isAvailable
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard available, await service.supportsWatch(vmID: vmID) else {
                    continuation.finish()
                    return
                }
                var watch: String?
                do {
                    // The daemon registers a watch even when its request is cancelled,
                    // and caps live watches per client. Let the start request finish
                    // outside this task's cancellation so its id is always released.
                    let id = try await Task.detached {
                        try await service.watch(vmID: vmID, directories: directories)
                    }.value
                    watch = id
                    try Task.checkCancellation()
                    var sequence: UInt64 = 0
                    while !Task.isCancelled {
                        let result = try await service.poll(vmID: vmID, watch: id, after: sequence, timeoutMs: 25_000)
                        sequence = result.sequence
                        let changed = result.overflow ? directories : result.directories
                        if !changed.isEmpty { continuation.yield(changed) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                // The daemon caps live watches per client, so release this one even
                // though this task is cancelled (a cancelled task sends no requests).
                if let watch { Task.detached { await service.unwatch(vmID: vmID, watch: watch) } }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Downloads a remote file into the local preview cache.
    nonisolated func downloadFile(path: String, to localURL: URL) async throws {
        guard isAvailable else { throw FileExplorerError.providerUnavailable }
        try await service.download(vmID: vmID, path: path, to: localURL)
    }
}

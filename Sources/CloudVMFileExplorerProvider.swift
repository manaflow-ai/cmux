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
        commandRunner: (any CloudFileExplorerCommandRunning)? = nil
    ) {
        self.id = UUID()
        self.target = target
        self.vmID = vmID
        self.displayTarget = displayTarget
        self.homePath = homePath
        self.isAvailable = isAvailable
        self.service = CloudFileExplorerService(commandRunner: commandRunner ?? LiveCloudFileExplorerCommandRunner(target: target))
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

    /// Downloads a remote file into the local preview cache.
    nonisolated func downloadFile(path: String, to localURL: URL) async throws {
        guard isAvailable else { throw FileExplorerError.providerUnavailable }
        try await service.download(vmID: vmID, path: path, to: localURL)
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func createFile(path: String) async throws {
        guard isAvailable else { throw FileExplorerError.providerUnavailable }
        try await service.createFile(vmID: vmID, path: path)
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func createDirectory(path: String) async throws {
        guard isAvailable else { throw FileExplorerError.providerUnavailable }
        try await service.createDirectory(vmID: vmID, path: path)
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func rename(path: String, to destinationPath: String) async throws {
        guard isAvailable else { throw FileExplorerError.providerUnavailable }
        try await service.rename(vmID: vmID, path: path, to: destinationPath)
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func delete(path: String) async throws {
        guard isAvailable else { throw FileExplorerError.providerUnavailable }
        try await service.delete(vmID: vmID, path: path)
    }
}

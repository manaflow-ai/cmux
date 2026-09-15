import Foundation

/// An immutable Cloud filesystem identity with I/O owned by its service actor.
final class CloudVMFileExplorerProvider: RemoteFileExplorerProvider, Sendable {
    let vmID: String
    let displayTarget: String
    let homePath: String
    let isAvailable: Bool
    private let service: CloudFileExplorerService

    /// Creates a provider for one Cloud machine.
    init(
        vmID: String,
        displayTarget: String,
        homePath: String = "",
        isAvailable: Bool,
        commandRunner: any CloudFileExplorerCommandRunning = LiveCloudFileExplorerCommandRunner()
    ) {
        self.vmID = vmID
        self.displayTarget = displayTarget
        self.homePath = homePath
        self.isAvailable = isAvailable
        self.service = CloudFileExplorerService(commandRunner: commandRunner)
    }

    private init(provider: CloudVMFileExplorerProvider, homePath: String) {
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
    func resolveHomePath() async throws -> String {
        guard isAvailable else { throw FileExplorerError.providerUnavailable }
        return try await service.resolveHome(vmID: vmID)
    }

    /// Lists a directory on the Cloud machine.
    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        guard isAvailable else { throw FileExplorerError.providerUnavailable }
        return try await service.listDirectory(vmID: vmID, path: path, showHidden: showHidden)
    }

    /// Downloads a remote file into the local preview cache.
    func downloadFile(path: String, to localURL: URL) async throws {
        guard isAvailable else { throw FileExplorerError.providerUnavailable }
        try await service.download(vmID: vmID, path: path, to: localURL)
    }
}

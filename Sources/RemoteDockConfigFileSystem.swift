import CmuxRemoteSession
import Dispatch
import Foundation

struct RemoteDockConfigFileSystem: DockConfigFileSystem {
    private let controller: RemoteSessionCoordinator?

    init(controller: RemoteSessionCoordinator?) {
        self.controller = controller
    }

    func metadata(at path: String, deadline: DispatchTime) async throws -> DockConfigFileMetadata {
        let controller = try readyController()
        return try await Task.detached(priority: .utility) {
            let stat = try controller.statRemoteFile(
                path: path,
                timeout: try Self.remainingTimeout(until: deadline)
            )
            let kind = stat.kind.map { kind in
                switch kind {
                case .file: DockConfigFileMetadata.Kind.file
                case .directory: DockConfigFileMetadata.Kind.directory
                case .other: DockConfigFileMetadata.Kind.other
                }
            }
            return DockConfigFileMetadata(exists: stat.exists, kind: kind, size: stat.size)
        }.value
    }

    func readFile(at path: String, deadline: DispatchTime) async throws -> Data {
        let controller = try readyController()
        return try await Task.detached(priority: .utility) {
            try controller.readRemoteFile(
                path: path,
                timeout: try Self.remainingTimeout(until: deadline)
            )
        }.value
    }

    private static func remainingTimeout(until deadline: DispatchTime) throws -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline.uptimeNanoseconds > now else {
            throw NSError(domain: "cmux.dock.remote", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "timed out resolving remote Dock config",
            ])
        }
        return Double(deadline.uptimeNanoseconds - now) / 1_000_000_000
    }

    private func readyController() throws -> RemoteSessionCoordinator {
        guard let controller else {
            throw NSError(domain: "cmux.dock.remote", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon is not ready",
            ])
        }
        return controller
    }
}

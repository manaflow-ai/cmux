import Dispatch
import Foundation

/// Filesystem seam used to resolve Dock configuration without assuming that
/// workspace paths live on the Mac.
protocol DockConfigFileSystem: Sendable {
    func metadata(at path: String, deadline: DispatchTime) async throws -> DockConfigFileMetadata
    func readFile(at path: String, deadline: DispatchTime) async throws -> Data
}

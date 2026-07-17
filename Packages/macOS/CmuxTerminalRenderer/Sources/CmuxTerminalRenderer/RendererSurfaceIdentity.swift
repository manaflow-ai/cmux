public import Foundation

/// A surface identity qualified by its worker generation.
///
/// The generation rejects delayed messages from a worker after that workspace
/// process has exited and a later registration has created a fresh process.
public struct RendererSurfaceIdentity: Codable, Hashable, Sendable {
    public let workspaceID: UUID
    public let surfaceID: UUID
    public let generation: UInt64

    public init(workspaceID: UUID, surfaceID: UUID, generation: UInt64) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.generation = generation
    }
}

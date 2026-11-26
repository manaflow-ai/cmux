import Foundation

extension GhosttyMouseSessionLedger {
    /// Identity of the native surface that owns a session.
    struct SurfaceIdentity: Hashable, Sendable {
        let surfaceID: UUID
        let runtimeGeneration: UInt64
        let nativeAddress: UInt
    }
}

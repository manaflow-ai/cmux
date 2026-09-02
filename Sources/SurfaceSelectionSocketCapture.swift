import Foundation

/// Socket identity paired with an immutable panel selection snapshot.
nonisolated struct SurfaceSelectionSocketCapture: Sendable {
    let snapshot: SurfaceSelectionSnapshot
    let workspaceID: UUID
    let surfaceID: UUID
    let windowID: UUID?
    let workspaceRef: String
    let surfaceRef: String
    let windowRef: String?
}

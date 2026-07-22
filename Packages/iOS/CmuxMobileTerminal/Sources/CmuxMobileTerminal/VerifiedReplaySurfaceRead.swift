#if canImport(UIKit)
import GhosttyKit

/// Immutable payload dereferenced only by the surface's serial Ghostty queue.
nonisolated struct VerifiedReplaySurfaceRead: @unchecked Sendable {
    // Safety: the raw surface pointer is used only on `GhosttySurfaceWorkQueue`,
    // which also owns output, rendering, export, and eventual surface free.
    let surface: ghostty_surface_t
    let generation: UInt64
    let surfaceID: String
    let stateSeq: UInt64
    let renderEpoch: String
    let renderRevision: UInt64
    let expectedCursorColor: String?
    let configuredCursorColor: String?
}

/// Tokened render invocation dereferenced only by the surface's serial queue.
nonisolated struct VerifiedReplayRenderSubmission: @unchecked Sendable {
    // Safety: the surface pointer remains owned by GhosttySurfaceView and every
    // use is enqueued on the same generation-bound surface work queue.
    let surface: ghostty_surface_t
    let token: UInt64
}
#endif

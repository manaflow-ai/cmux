#if canImport(UIKit)
import CMUXMobileCore
import Foundation
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
    /// Anchor of the frame being verified. Screen-anchored frames are read
    /// back against the ACTIVE area: the local viewport may be scrolled into
    /// local scrollback, and a viewport-anchored read would compare history
    /// rows against the frame's grid and spuriously fail verification.
    let anchor: MobileTerminalRenderGridFrame.Anchor
}

/// Tokened render invocation dereferenced only by the surface's serial queue.
nonisolated struct VerifiedReplayRenderSubmission: @unchecked Sendable {
    // Safety: the surface pointer remains owned by GhosttySurfaceView and every
    // use is enqueued on the same generation-bound surface work queue.
    let surface: ghostty_surface_t
    let token: UInt64
}

extension VerifiedReplaySurfaceRead {
    /// Exports the locally reconstructed grid on the serial Ghostty queue.
    /// Keeping this operation on the read payload avoids attaching a pure
    /// export helper to the stateful UIKit surface type.
    func exportGridSynchronously() -> MobileTerminalRenderGridFrame? {
        let exported = surfaceID.withCString { pointer in
            // Screen-anchored frames verify against the ACTIVE area so a
            // locally scrolled viewport cannot fail the read-back;
            // viewport-anchored frames keep the historical viewport read.
            ghostty_surface_render_grid_json_v2(
                surface,
                pointer,
                UInt(surfaceID.utf8.count),
                stateSeq,
                0,
                false,
                anchor == .screen
            )
        }
        defer { ghostty_string_free(exported) }
        guard let pointer = exported.ptr, exported.len > 0 else { return nil }
        let data = Data(bytes: pointer, count: Int(exported.len))
        guard var frame = try? MobileTerminalRenderGridFrame.decode(data) else { return nil }
        frame.renderEpoch = renderEpoch
        frame.renderRevision = renderRevision
        return frame
    }
}
#endif

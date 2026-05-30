import CmuxTerminalAccess
import Foundation

/// Phase 0 stub forwarders for ``TerminalController`` — the surface-
/// provider seam ``AppSurfaceProvider`` calls into.
///
/// Each method here throws ``TerminalAccessError/unknownSurface`` (or
/// returns an empty/nil value where the protocol requires a value).
/// Task 0.24 replaces each stub with the real extract from the v1/v2
/// socket dispatch code, one at a time, each with its own
/// red→green characterization test.
///
/// Keeping these stubs in a dedicated `TerminalController+` extension
/// file (one type per file per project policy) means the 20k-line
/// `TerminalController.swift` isn't perturbed during Phase 0 — the
/// extracts in Task 0.24 will move the real bodies here from the
/// existing dispatch sites.
extension TerminalController {
    /// Enumerate every live cmux terminal surface as ``SurfaceInfo``
    /// snapshots (canonical sidebar order).
    ///
    /// Phase 0 stub returns `[]`. Task 0.24.b replaces this with the
    /// real impl that mirrors the existing v2 `surface.list`
    /// enumeration.
    @MainActor
    func v2EnumerateSurfaceInfos() -> [SurfaceInfo] { [] }

    /// Resolve a ``SurfaceHandle`` to its current ``SurfaceInfo``
    /// snapshot, or `nil` when the surface is no longer alive.
    ///
    /// Phase 0 stub returns `nil`. Task 0.24.a replaces this with the
    /// real impl that mirrors the existing v2 `v2ResolveHandleRef`
    /// + descriptor projection.
    @MainActor
    func v2Resolve(handle: SurfaceHandle) -> SurfaceInfo? { nil }

    /// Read rendered UTF-8 text from the given surface region.
    ///
    /// Phase 0 stub throws ``TerminalAccessError/unknownSurface``.
    /// Task 0.24.c replaces this with the real impl extracted from
    /// `readTerminalTextBase64` (the three-tag SCREEN+SURFACE+ACTIVE
    /// merge for `region == .screen`).
    func readSurfaceText(uuid: UUID, region: ScreenRegion) async throws -> String {
        throw TerminalAccessError.unknownSurface
    }

    /// Enqueue raw UTF-8 bytes onto the surface's PTY.
    ///
    /// Phase 0 stub throws ``TerminalAccessError/unknownSurface``.
    /// Task 0.24.d replaces this with the real impl extracted from
    /// `case "surface.send_text"`.
    func writeSurfaceText(uuid: UUID, bytes: Data) async throws {
        throw TerminalAccessError.unknownSurface
    }

    /// Encode and send a single ``KeyEvent`` via the existing
    /// `sendKeyToPanel` path.
    ///
    /// Phase 0 stub throws ``TerminalAccessError/unknownSurface``.
    /// Task 0.24.d replaces this with the real impl extracted from
    /// `case "surface.send_key"`.
    func writeSurfaceKey(uuid: UUID, event: KeyEvent) async throws {
        throw TerminalAccessError.unknownSurface
    }

    /// Dispatch a ``MouseEvent`` via the direct
    /// `ghostty_surface_mouse_*` C entrypoints (D16 — never through a
    /// synthesized `NSEvent`).
    ///
    /// Phase 0 stub throws ``TerminalAccessError/unknownSurface``.
    /// Task 0.24.e replaces this with the real impl.
    func writeSurfaceMouse(uuid: UUID, event: MouseEvent) async throws {
        throw TerminalAccessError.unknownSurface
    }

    /// Notify the surface that focus was gained or lost, without
    /// changing macOS app focus (socket-focus policy).
    ///
    /// Phase 0 stub throws ``TerminalAccessError/unknownSurface``.
    /// Task 0.24.e replaces this with the real impl that calls
    /// `ghostty_surface_set_focus` directly.
    func setSurfaceFocus(uuid: UUID, gained: Bool) async throws {
        throw TerminalAccessError.unknownSurface
    }

    /// Remaining bytes that may be enqueued onto the per-surface
    /// input queue before ``TerminalAccessError/payloadTooLarge`` fires.
    ///
    /// Phase 0 stub returns `0` (write paths through the service
    /// short-circuit on the unknown-surface error before reading this).
    /// Task 0.24.e replaces this with the per-panel queue counter.
    nonisolated func pendingInputCapacityRemaining(uuid: UUID) -> Int { 0 }
}

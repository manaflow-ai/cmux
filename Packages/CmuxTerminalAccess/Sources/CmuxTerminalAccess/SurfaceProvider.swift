// SPDX-License-Identifier: MIT

import Foundation

/// Protocol seam between the transport-neutral
/// ``TerminalAccessService`` and the live cmux app surface registry.
///
/// Per Errata E1/D1 every method is `async throws` and the protocol
/// itself is `Sendable`. Phase 0 ships this shape; Phase 1/2 only
/// **use** it. ``DefaultTerminalAccessService`` composes higher-level
/// operations (text writes with submit-CR, paste atomicity, mouse
/// dispatch, focus) from these primitives — there are intentionally
/// no `writeKeys` / `writeRaw` / `writePaste` / `attachRawOutput`
/// requirements here.
///
/// Per Errata E20, ``readCells(surface:region:)`` is a **required**
/// member with no default implementation. Conformers either provide
/// the real ghostty patch #1 implementation (Phase 1) or throw
/// ``TerminalAccessError/unsupported(reason:)``. Conformers cannot
/// silently inherit a default.
///
/// The Phase 2 raw-output tap (`attachRawOutput`) is added as a
/// protocol extension in Task 2.15 and is **not** part of this Phase
/// 0 required surface.
public protocol SurfaceProvider: Sendable {
    /// Enumerate every live cmux terminal surface, in canonical
    /// sidebar order.
    func listSurfaces() async throws -> [SurfaceInfo]

    /// Resolve a handle to its current ``SurfaceInfo`` snapshot, or
    /// `nil` when the surface is no longer alive.
    func resolve(_ handle: SurfaceHandle) async throws -> SurfaceInfo?

    /// Read rendered UTF-8 text for the given region.
    func readText(surface: SurfaceInfo, region: ScreenRegion) async throws -> String

    /// Read a structured ``CellGrid``. Phase 0 conformers may throw
    /// ``TerminalAccessError/unsupported(reason:)``; ghostty patch #1
    /// in Phase 1 supplies the real implementation.
    func readCells(surface: SurfaceInfo, region: ScreenRegion) async throws -> CellGrid

    /// Write literal UTF-8 bytes via `ghostty_surface_text`.
    func writeText(surface: SurfaceInfo, bytes: Data) async throws

    /// Encode and send a single key press through `ghostty_surface_key`.
    func writeKey(surface: SurfaceInfo, event: KeyEvent) async throws

    /// Send a mouse event via `ghostty_surface_mouse_button` /
    /// `mouse_pos` / `mouse_scroll`. Per D16 implementations must
    /// **not** synthesize `NSEvent` instances.
    func writeMouse(surface: SurfaceInfo, event: MouseEvent) async throws

    /// Report focus gained or lost via `ghostty_surface_set_focus`.
    /// Per the socket-focus policy this does **not** change macOS app
    /// focus.
    func setFocus(surface: SurfaceInfo, gained: Bool) async throws

    /// Remaining bytes that may be enqueued before
    /// ``TerminalAccessError/payloadTooLarge`` fires. Synchronous —
    /// Phase 0 capacity bookkeeping is a fast in-memory counter, so
    /// callers do not need to suspend to read it.
    func pendingInputCapacityRemaining(surface: SurfaceInfo) -> Int
}

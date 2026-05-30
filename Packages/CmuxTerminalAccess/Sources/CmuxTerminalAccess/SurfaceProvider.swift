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

    /// Observe the close of `handle`.
    ///
    /// The returned lifetime token must be retained by the caller for
    /// the duration of the observation; releasing it (or letting it
    /// deallocate) tears the observer down. `onClose` fires at most
    /// once when the underlying surface goes away.
    ///
    /// Phase 2 uses this seam to drive ``OutputSubscription/signalEnd()``
    /// when the surface closes underneath an active stream. The default
    /// extension below returns a fresh `NSObject` and never fires
    /// `onClose`; live providers must override it to wire the real
    /// surface-lifecycle signal.
    ///
    /// Declared on the protocol (not just in an extension) so dynamic
    /// dispatch routes to the conformer's override when callers hold
    /// the provider as `any SurfaceProvider`.
    ///
    /// - Parameters:
    ///   - handle: Target surface.
    ///   - onClose: Fired exactly once when the surface closes.
    /// - Returns: An opaque lifetime token; release stops observation.
    func observeClose(
        _ handle: SurfaceHandle,
        onClose: @escaping @Sendable () -> Void
    ) async throws -> AnyObject
}

public extension SurfaceProvider {
    /// Observe the close of `handle`. The default implementation is a
    /// no-op that returns a fresh `NSObject` lifetime token; live
    /// providers (in the app target) override this to fire `onClose`
    /// exactly once when the underlying surface goes away.
    ///
    /// The returned token must be retained by the caller for the
    /// lifetime of the observation; releasing it (or letting it
    /// deallocate) tears the observer down. Phase 2 uses this seam to
    /// drive ``OutputSubscription/signalEnd()`` when the surface closes
    /// underneath an active stream.
    ///
    /// - Parameters:
    ///   - handle: Target surface.
    ///   - onClose: Fired exactly once when the surface closes.
    /// - Returns: An opaque lifetime token; release stops observation.
    func observeClose(
        _ handle: SurfaceHandle,
        onClose: @escaping @Sendable () -> Void
    ) async throws -> AnyObject {
        _ = handle
        _ = onClose
        return NSObject()
    }
}

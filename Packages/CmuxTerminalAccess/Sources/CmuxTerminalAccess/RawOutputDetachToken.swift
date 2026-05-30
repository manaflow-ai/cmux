// SPDX-License-Identifier: MIT

/// Opaque handle returned by the Phase 2 raw-output seam.
///
/// `SurfaceProvider.attachRawOutput(surface:onBytes:)` is added as a
/// protocol extension in Task 2.15. Holding the returned token keeps
/// the raw-output tap attached; releasing it (or calling
/// ``detach()``) tears the tap down. Implementations must make
/// ``detach()`` idempotent.
///
/// The type lives in Phase 0 so it is available when Phase 2 wires up
/// the tap.
public protocol RawOutputDetachToken: AnyObject, Sendable {
    /// Detach the raw-output tap. Safe to call more than once.
    func detach()
}

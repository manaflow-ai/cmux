#if canImport(UIKit)
import GhosttyKit

/// Carrier for a Ghostty C surface pointer across the queue boundary.
///
/// Safety: the raw pointer is intentionally `@unchecked Sendable` only as an
/// opaque handle. It must be dereferenced exclusively on the
/// ``GhosttySurfaceWorkExecutor`` queue for the generation that owns it, where
/// all `process_output`, geometry, render, text-read, and free calls are
/// serialized.
struct GhosttySurfaceWorkHandle: @unchecked Sendable {
    let surface: ghostty_surface_t
}
#endif

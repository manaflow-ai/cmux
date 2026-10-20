public import Foundation
public import GhosttyKit

/// A retained byte-tee installation on one runtime surface.
///
/// The lease wraps the retained C-callback userdata; the surface model calls
/// ``release()`` exactly where it released the legacy `Unmanaged` context so
/// the userdata's lifetime is unchanged.
public protocol TerminalByteTeeLease: AnyObject, Sendable {
    /// Balances the retain taken when the tee was installed.
    func release()
}

/// Installs and tears down the shared PTY output tee for runtime surfaces.
///
/// The app routes tee'd bytes to opt-in terminal-output consumers while
/// preserving one libghostty callback per surface.
public protocol TerminalByteTeeBinding: AnyObject, Sendable {
    /// Installs the PTY tee callback on a freshly created runtime surface.
    ///
    /// - Parameters:
    ///   - surface: The live runtime surface.
    ///   - workspaceID: The workspace that owns the surface.
    ///   - surfaceID: The owning surface id used to key tee state.
    /// - Returns: The retained lease the caller releases on teardown.
    @MainActor
    func installTee(
        on surface: ghostty_surface_t,
        workspaceID: UUID,
        surfaceID: UUID
    ) -> any TerminalByteTeeLease

    /// Drops all tee/replay state keyed by a surface id.
    ///
    /// - Parameter surfaceID: The surface id being torn down.
    @MainActor
    func dropSurface(surfaceID: UUID)
}

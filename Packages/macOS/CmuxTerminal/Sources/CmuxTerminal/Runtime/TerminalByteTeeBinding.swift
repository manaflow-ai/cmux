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

/// A callback and retained userdata prepared before `ghostty_surface_new`.
/// Installing this pair in the initial C config closes the startup-byte race
/// that exists when a tee is attached after Ghostty starts its IO thread.
public struct TerminalByteTeeInstallation {
    public let callback: ghostty_pty_tee_cb
    public let userdata: UnsafeMutableRawPointer
    public let lease: any TerminalByteTeeLease

    public init(
        callback: @escaping ghostty_pty_tee_cb,
        userdata: UnsafeMutableRawPointer,
        lease: any TerminalByteTeeLease
    ) {
        self.callback = callback
        self.userdata = userdata
        self.lease = lease
    }
}

/// Installs and tears down the shared PTY output tee for runtime surfaces.
///
/// The app routes tee'd bytes to opt-in terminal-output consumers while
/// preserving one libghostty callback per surface.
public protocol TerminalByteTeeBinding: AnyObject, Sendable {
    /// Prepares the PTY tee callback before a runtime surface is created.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace that owns the surface.
    ///   - surfaceID: The owning surface id used to key tee state.
    ///   - surfaceGeneration: The worker mirror generation receiving bytes.
    /// - Returns: The retained lease the caller releases on teardown.
    @MainActor
    func prepareTee(
        workspaceID: UUID,
        surfaceID: UUID,
        surfaceGeneration: UInt64
    ) -> TerminalByteTeeInstallation

    /// Drops all tee/replay state keyed by a surface id.
    ///
    /// - Parameter surfaceID: The surface id being torn down.
    @MainActor
    func dropSurface(surfaceID: UUID)
}

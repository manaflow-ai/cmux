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

    /// Requests that provider-specific context-pressure parser state be reset
    /// to a new surface-owned generation before the tee consumes its next PTY
    /// output chunk.
    ///
    /// The request is deliberately asynchronous across the PTY callback
    /// boundary: the callback owns parser mutation, while callers such as the
    /// main-actor recovery coordinator only publish a short-lived reset edge.
    /// - Parameter generation: Monotonic generation allocated by the owning
    ///   ``TerminalSurface``.
    func resetContextPressureDetectors(to generation: UInt64)

    /// Enables or disables provider-pressure parsing for this runtime surface.
    ///
    /// The flag is consumed synchronously by the serialized PTY callback. The
    /// caller should enable it only after an authoritative managed-session
    /// binding exists, and disable it before that binding is removed.
    /// - Parameter enabled: Whether this surface is currently eligible for
    ///   context-pressure detection.
    func setContextPressureMonitoringEnabled(_ enabled: Bool)
}

public extension TerminalByteTeeLease {
    /// Default no-op for tee leases that do not install context-pressure
    /// detectors.
    func resetContextPressureDetectors(to _: UInt64) {}

    /// Default no-op for tee leases that do not install context-pressure
    /// detectors.
    func setContextPressureMonitoringEnabled(_: Bool) {}
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
    ///   - contextPressureDetectorGeneration: The initial parser generation for
    ///     this runtime-surface lifetime.
    ///   - contextPressureMonitoringEnabled: Whether provider-pressure parsing
    ///     is eligible when the callback is installed.
    /// - Returns: The retained lease the caller releases on teardown.
    @MainActor
    func installTee(
        on surface: ghostty_surface_t,
        workspaceID: UUID,
        surfaceID: UUID,
        contextPressureDetectorGeneration: UInt64,
        contextPressureMonitoringEnabled: Bool
    ) -> any TerminalByteTeeLease

    /// Drops all tee/replay state keyed by a surface id.
    ///
    /// - Parameter surfaceID: The surface id being torn down.
    @MainActor
    func dropSurface(surfaceID: UUID)
}

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

    /// Mirrors the latest backing-pixel geometry to an external renderer.
    @MainActor
    func updateRendererSize(
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        scaleX: Double,
        scaleY: Double
    )

    /// Mirrors focus and occlusion state used by cursor rendering.
    func updateRendererFocus(_ focused: Bool)
    func updateRendererOcclusion(_ visible: Bool)
    func sendRendererMousePosition(x: Double, y: Double, modifiers: UInt32)
    func sendRendererMouseButton(state: UInt32, button: UInt32, modifiers: UInt32)
    func sendRendererMouseScroll(x: Double, y: Double, packedModifiers: Int32)
    func sendRendererMousePressure(stage: UInt32, pressure: Double)
    func sendRendererKey(_ event: ghostty_input_key_s)
    func sendRendererText(_ text: String, marked: Bool)
    func sendRendererUnmarkText()
    func sendRendererBindingAction(_ action: String)
    func updateRendererColorScheme(_ rawValue: UInt32)
    func reloadRendererConfiguration()
}

public extension TerminalByteTeeLease {
    @MainActor
    func updateRendererSize(
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        scaleX: Double,
        scaleY: Double
    ) {}

    func updateRendererFocus(_ focused: Bool) {}
    func updateRendererOcclusion(_ visible: Bool) {}
    func sendRendererMousePosition(x: Double, y: Double, modifiers: UInt32) {}
    func sendRendererMouseButton(state: UInt32, button: UInt32, modifiers: UInt32) {}
    func sendRendererMouseScroll(x: Double, y: Double, packedModifiers: Int32) {}
    func sendRendererMousePressure(stage: UInt32, pressure: Double) {}
    func sendRendererKey(_ event: ghostty_input_key_s) {}
    func sendRendererText(_ text: String, marked: Bool) {}
    func sendRendererUnmarkText() {}
    func sendRendererBindingAction(_ action: String) {}
    func updateRendererColorScheme(_ rawValue: UInt32) {}
    func reloadRendererConfiguration() {}
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
        owner: TerminalSurface,
        view: any TerminalSurfaceNativeViewing,
        workspaceID: UUID,
        surfaceID: UUID,
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        scaleX: Double,
        scaleY: Double,
        fontSize: Float,
        context: UInt32
    ) -> any TerminalByteTeeLease

    /// Drops all tee/replay state keyed by a surface id.
    ///
    /// - Parameter surfaceID: The surface id being torn down.
    @MainActor
    func dropSurface(surfaceID: UUID)
}

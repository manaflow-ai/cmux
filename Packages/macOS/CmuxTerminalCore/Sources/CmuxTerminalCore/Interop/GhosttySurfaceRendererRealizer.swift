public import GhosttyKit

// lint:allow free-function — @_silgen_name FFI declaration: the symbol is
// exported by libghostty without a public header entry, so it must be declared
// as a bare function signature for the linker to bind.
@_silgen_name("ghostty_surface_set_renderer_realized")
private func cmux_ghostty_surface_set_renderer_realized(_ surface: ghostty_surface_t, _ realized: Bool) -> Bool

/// Sets renderer-realization state for a Ghostty runtime surface.
public struct GhosttySurfaceRendererRealizer: Sendable {
    /// Creates a renderer-realization service.
    public init() {}

    /// Sets whether a runtime surface owns realized GPU renderer resources.
    ///
    /// Mirrors `ghostty_surface_set_renderer_realized` from the cmux libghostty
    /// fork. The call asks Ghostty to enqueue a renderer realize/release
    /// transition without blocking the caller.
    ///
    /// - Parameters:
    ///   - surface: The live runtime surface to update.
    ///   - realized: Whether the surface should hold renderer resources.
    /// - Returns: Whether Ghostty accepted the renderer transition message.
    @discardableResult
    public func setRealized(_ surface: ghostty_surface_t, _ realized: Bool) -> Bool {
        cmux_ghostty_surface_set_renderer_realized(surface, realized)
    }
}

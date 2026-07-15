public import GhosttyKit

// lint:allow free-function — @_silgen_name FFI declaration: the symbol is
// exported by libghostty without a public header entry, so it must be declared
// as a bare function signature for the linker to bind.
@_silgen_name("ghostty_surface_clear_selection")
private func cmux_ghostty_surface_clear_selection(_ surface: ghostty_surface_t) -> Bool

/// The one sanctioned seam for libghostty symbols that are linked by name
/// rather than imported through the GhosttyKit header.
///
/// cmux's libghostty fork exports a small number of symbols that are not part
/// of the public `ghostty.h` surface. Each one is declared privately in this
/// file with `@_silgen_name` and exposed as a static member here, so every
/// header-less FFI binding in the codebase lives behind a single type instead
/// of being scattered as bare function declarations.
// lint:allow namespace-type — sanctioned FFI seam: a holder for header-less
// @_silgen_name libghostty bindings; there is nothing to instantiate.
public struct GhosttyRuntimeCInterop {
    private init() {}

    /// Creates a runtime surface with a separate scrollback upper bound.
    ///
    /// The limit stays outside ``ghostty_surface_config_s`` so adding this cmux
    /// extension does not change that public C structure's byte layout.
    ///
    /// - Parameters:
    ///   - app: The live Ghostty application that will own the surface.
    ///   - config: The standard Ghostty surface configuration.
    ///   - scrollbackLimitBytes: The per-surface upper bound, or zero to inherit
    ///     the configured `scrollback-limit`.
    /// - Returns: The created surface, or `nil` when Ghostty initialization fails.
    public static func createSurface(
        app: ghostty_app_t,
        config: UnsafePointer<ghostty_surface_config_s>,
        scrollbackLimitBytes: Int
    ) -> ghostty_surface_t? {
        ghostty_surface_new_with_scrollback_limit(app, config, scrollbackLimitBytes)
    }

    /// Clears the active selection on a runtime surface.
    ///
    /// Mirrors `ghostty_surface_clear_selection` from the cmux libghostty
    /// fork. The surface pointer must be a live `ghostty_surface_t`; passing a
    /// freed pointer is undefined behavior, exactly as with any other ghostty
    /// C call.
    ///
    /// - Parameter surface: The live runtime surface to clear.
    /// - Returns: Whether the runtime cleared a selection.
    @discardableResult
    public static func clearSelection(_ surface: ghostty_surface_t) -> Bool {
        cmux_ghostty_surface_clear_selection(surface)
    }

}

public import GhosttyKit

// lint:allow free-function — @_silgen_name FFI declaration: the symbol is
// exported by libghostty without a public header entry, so it must be declared
// as a bare function signature for the linker to bind.
@_silgen_name("ghostty_surface_clear_selection")
private func cmux_ghostty_surface_clear_selection(_ surface: ghostty_surface_t) -> Bool

// lint:allow free-function — @_silgen_name FFI declaration: see
// `cmux_ghostty_surface_clear_selection` above for the ownership rationale.
@_silgen_name("ghostty_surface_select_screen_rows")
private func cmux_ghostty_surface_select_screen_rows(
    _ surface: ghostty_surface_t,
    _ topY: UInt32,
    _ bottomY: UInt32
) -> Bool

// lint:allow free-function — @_silgen_name FFI declaration: see
// `cmux_ghostty_surface_clear_selection` above for the ownership rationale.
@_silgen_name("ghostty_surface_selection_screen_rows")
private func cmux_ghostty_surface_selection_screen_rows(
    _ surface: ghostty_surface_t,
    _ topY: UnsafeMutablePointer<UInt32>,
    _ bottomY: UnsafeMutablePointer<UInt32>
) -> Bool

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

    /// Selects inclusive absolute screen rows on a runtime surface.
    ///
    /// Mirrors `ghostty_surface_select_screen_rows` from the cmux libghostty
    /// fork. The runtime stores the selection as Ghostty tracked pins, so
    /// later scrollback pruning can move or clip the selection without the host
    /// guessing from scrollbar deltas.
    ///
    /// - Parameters:
    ///   - surface: The live runtime surface to update.
    ///   - selectedRows: The inclusive absolute screen-row range to select.
    /// - Returns: Whether the runtime accepted the row selection.
    @discardableResult
    public static func selectScreenRows(
        _ surface: ghostty_surface_t,
        selectedRows: ClosedRange<UInt64>
    ) -> Bool {
        guard let lower = UInt32(exactly: selectedRows.lowerBound),
              let upper = UInt32(exactly: selectedRows.upperBound) else { return false }
        return cmux_ghostty_surface_select_screen_rows(surface, lower, upper)
    }

    /// Returns the active runtime selection as inclusive absolute screen rows.
    ///
    /// - Parameter surface: The live runtime surface to query.
    /// - Returns: The current selected row range, or `nil` when no tracked
    ///   selection can be represented as screen rows.
    public static func selectionScreenRows(_ surface: ghostty_surface_t) -> ClosedRange<UInt64>? {
        var lower: UInt32 = 0
        var upper: UInt32 = 0
        guard cmux_ghostty_surface_selection_screen_rows(surface, &lower, &upper) else { return nil }
        return UInt64(lower) ... UInt64(upper)
    }
}

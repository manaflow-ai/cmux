public import Darwin
public import Foundation
public import GhosttyKit

// lint:allow free-function — @_silgen_name FFI declaration: the symbol is
// exported by libghostty without a public header entry, so it must be declared
// as a bare function signature for the linker to bind.
@_silgen_name("ghostty_surface_clear_selection")
private func cmux_ghostty_surface_clear_selection(_ surface: ghostty_surface_t) -> Bool

// The ExternalHover diagnostics entry is part of cmux's libghostty fork but
// is not present in the public GhosttyKit header. Keep this binding beside
// the other header-less symbols and decode it into the package-owned value
// type before returning to callers.
private struct CmuxExternalHoverDiagnosticsEntry {
    var event: UInt64 = 0
    var source: UInt8 = 0
    var reason: UInt8 = 0
    var verdict: UInt8 = 0
    var flags: UInt8 = 0
    var seq: UInt32 = 0
}

// lint:allow free-function — @_silgen_name FFI declaration for the cmux
// libghostty extension, whose symbol is absent from the public header.
@_silgen_name("ghostty_surface_drain_external_hover_diagnostics")
private func cmux_ghostty_surface_drain_external_hover_diagnostics(
    _ surface: ghostty_surface_t,
    _ outEntries: UnsafeMutableRawPointer?,
    _ outCapacity: UInt,
    _ outDroppedCountCumulative: UnsafeMutablePointer<UInt64>?
) -> UInt

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
    private static let initializationLock = NSLock()
    nonisolated(unsafe) private static var initializationResult: Int32?

    private init() {}

    /// Initializes libghostty once for the process.
    public static func initialize() -> Int32 {
        initializationLock.lock()
        defer { initializationLock.unlock() }

        if let initializationResult {
            return initializationResult
        }

        if getenv("NO_COLOR") != nil {
            unsetenv("NO_COLOR")
        }

        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        // ghostty_init applies the user's locale. Config parsing can now be the
        // first caller, before GhosttyApp's own re-pin, so restore the
        // CoreUI-safe numeric locale here for every caller.
        _ = setlocale(LC_NUMERIC, "C")
        initializationResult = result
        return result
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

    /// Drains the native ExternalHover diagnostics ring through cmux's
    /// header-less libghostty extension and decodes its fixed POD entries.
    public static func drainExternalHoverDiagnostics(
        _ surface: ghostty_surface_t,
        capacity: Int = 64
    ) -> (entries: [ExternalHoverDiagEntryValue], droppedCountCumulative: UInt64) {
        guard capacity > 0 else { return (entries: [], droppedCountCumulative: 0) }
        var buffer = [CmuxExternalHoverDiagnosticsEntry](
            repeating: CmuxExternalHoverDiagnosticsEntry(), count: capacity
        )
        var droppedCountCumulative: UInt64 = 0
        let count = buffer.withUnsafeMutableBytes { rawBuffer in
            cmux_ghostty_surface_drain_external_hover_diagnostics(
                surface,
                rawBuffer.baseAddress,
                UInt(capacity),
                &droppedCountCumulative
            )
        }
        let entries = buffer.prefix(min(Int(count), buffer.count)).map { entry in
            ExternalHoverDiagEntryValue(
                event: entry.event,
                source: entry.source,
                reason: entry.reason,
                verdict: entry.verdict,
                flags: entry.flags,
                seq: entry.seq
            )
        }
        return (entries: entries, droppedCountCumulative: droppedCountCumulative)
    }

}

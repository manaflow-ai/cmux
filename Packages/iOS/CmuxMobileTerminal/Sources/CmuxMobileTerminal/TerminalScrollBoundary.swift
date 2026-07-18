#if canImport(UIKit)
import GhosttyKit

/// Ghostty's authoritative primary-screen viewport range.
struct TerminalScrollBoundary: Equatable, Sendable {
    let total: UInt64
    let offset: UInt64
    let len: UInt64

    private var maximumOffset: UInt64 {
        total > len ? total - len : 0
    }

    /// Whether a wheel delta points outward from a loaded history boundary.
    /// A screen without scrollback fails open so alternate-screen TUIs keep
    /// receiving their wheel input.
    func suppresses(lines: Double) -> Bool {
        guard lines != 0, total > len else { return false }
        if lines > 0 {
            return offset == 0
        }
        return offset >= maximumOffset
    }
}

/// Thread-safe direct reads and compare-and-swap restoration for one Ghostty
/// surface. The C API owns the terminal lock, so callers never restore from an
/// asynchronously cached scrollbar callback.
nonisolated struct GhosttySurfaceScrollPosition {
    let surface: ghostty_surface_t

    func boundary() -> TerminalScrollBoundary? {
        var snapshot = ghostty_surface_scrollbar_s()
        guard ghostty_surface_scrollbar(surface, &snapshot) else { return nil }
        return TerminalScrollBoundary(
            total: snapshot.total,
            offset: snapshot.offset,
            len: snapshot.len
        )
    }

    func distanceFromBottom() -> UInt64? {
        var snapshot = ghostty_surface_scrollbar_s()
        guard ghostty_surface_scrollbar(surface, &snapshot) else { return nil }
        let maximumOffset = snapshot.total > snapshot.len ? snapshot.total - snapshot.len : 0
        return maximumOffset - min(snapshot.offset, maximumOffset)
    }

    func restore(_ distanceFromBottom: UInt64) -> Bool {
        var current = ghostty_surface_scrollbar_s()
        guard ghostty_surface_scrollbar(surface, &current) else { return false }
        let maximumOffset = current.total > current.len ? current.total - current.len : 0
        let target = maximumOffset - min(distanceFromBottom, maximumOffset)
        var positioned = ghostty_surface_scrollbar_s()
        return ghostty_surface_scroll_to_row_if_revision(
            surface,
            target,
            current.row_space_revision,
            &positioned
        ) && positioned.offset == target
    }
}
#endif

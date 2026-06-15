import Foundation

/// The Mac's resolved Ghostty terminal theme propagated to a paired phone so it
/// inherits the Mac's palette + default colors instead of a hardcoded Monokai.
///
/// All colors are `#RRGGBB` hex strings. ``palette`` is the 16-color ANSI
/// palette (indices 0...15) or `nil` when the Mac could not resolve a full
/// 16-color palette (so the phone keeps its consistent built-in fallback).
/// ``foreground`` / ``background`` / ``cursor`` are `nil` when the user has not
/// configured that default (so the phone keeps its own default for that color,
/// and a program's live OSC 10/11/12 still wins).
///
/// Resolving this walks the parsed Ghostty config and formats several NSColors,
/// so it must be computed off the per-keystroke render path and reused (cache it
/// and recompute only when the Ghostty config reloads) rather than rebuilt on
/// every render-grid export.
public struct MobileInheritedTerminalTheme: Equatable, Sendable {
    /// The 16-color ANSI palette (indices 0...15) as `#RRGGBB` hex, or `nil` when
    /// the Mac could not resolve a full 16-color palette.
    public var palette: [String]?
    /// The default foreground color as `#RRGGBB` hex, or `nil` when the user has
    /// not configured one (the phone keeps its own default).
    public var foreground: String?
    /// The default background color as `#RRGGBB` hex, or `nil` when the user has
    /// not configured one (the phone keeps its own default).
    public var background: String?
    /// The cursor color as `#RRGGBB` hex, or `nil` when the user has not
    /// configured one (the phone keeps its own default).
    public var cursor: String?

    /// Creates an inherited theme. Each color is an optional `#RRGGBB` hex string;
    /// see the property docs for what `nil` means per field.
    public init(
        palette: [String]? = nil,
        foreground: String? = nil,
        background: String? = nil,
        cursor: String? = nil
    ) {
        self.palette = palette
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
    }
}

extension MobileTerminalRenderGridFrame {
    /// Stamp the Mac's inherited theme onto a full snapshot. The palette always
    /// replaces the frame's (libghostty's grid JSON never carries it); the
    /// default colors only backfill where the program has not already set a
    /// dynamic default (OSC 10/11/12), so a running program's live colors win
    /// over the static theme. Meaningful only on a full frame; a delta drops the
    /// theme fields, so callers should skip this for deltas.
    public mutating func applyInheritedTheme(_ theme: MobileInheritedTerminalTheme) {
        // Enforce the same 16-entry invariant the frame initializer applies, so a
        // partial palette never reaches OSC 4 (which would mix inherited and
        // fallback colors). A non-16 palette is dropped, keeping the phone's
        // consistent built-in fallback.
        terminalPalette = (theme.palette?.count == 16) ? theme.palette : nil
        if terminalForeground == nil { terminalForeground = theme.foreground }
        if terminalBackground == nil { terminalBackground = theme.background }
        if terminalCursorColor == nil { terminalCursorColor = theme.cursor }
    }
}

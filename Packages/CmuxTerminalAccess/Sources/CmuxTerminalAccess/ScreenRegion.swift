// SPDX-License-Identifier: MIT

/// Region of the surface to read.
///
/// - ``viewport``: the currently visible rows.
/// - ``screen``: scrollback + active rows.
/// - ``scrollback``: ghostty `SURFACE` tag (misleadingly named).
///   On the alt screen, `scrollback` returns an empty string per spec §7
///   invariant.
public enum ScreenRegion: String, Sendable, Codable, CaseIterable {
    /// The currently visible rows.
    case viewport
    /// Scrollback combined with active rows.
    case screen
    /// ghostty `SURFACE` tag; empty on the alt screen.
    case scrollback
}

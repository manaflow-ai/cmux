// SPDX-License-Identifier: MIT

/// The serialization mode requested for a screen read. ``cells`` requires
/// ghostty patch #1 (lands in Phase 1); in Phase 0 the service rejects it
/// with ``TerminalAccessError/unsupported(reason:)`` (HTTP 415 per D18).
public enum ScreenFormat: String, Sendable, Codable, CaseIterable {
    /// Plain UTF-8 text rendering of the surface.
    case text
    /// Structured per-cell grid; requires ghostty patch #1.
    case cells
}

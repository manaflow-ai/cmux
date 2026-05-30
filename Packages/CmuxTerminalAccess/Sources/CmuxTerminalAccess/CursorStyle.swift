// SPDX-License-Identifier: MIT

/// Cursor presentation style as configured by the active program.
public enum CursorStyle: String, Sendable, Codable, Hashable {
    /// Solid block cursor.
    case block
    /// Underline cursor.
    case underline
    /// Vertical bar cursor.
    case bar
}

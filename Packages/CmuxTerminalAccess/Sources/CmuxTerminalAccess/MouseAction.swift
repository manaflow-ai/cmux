// SPDX-License-Identifier: MIT

/// Mouse action kind. Mirrors ghostty's apprt mouse API.
public enum MouseAction: String, Sendable, Codable, Hashable {
    /// Button press.
    case press
    /// Button release.
    case release
    /// Pointer move (drag if a button is held).
    case move
    /// Scroll wheel event.
    case scroll
}

// SPDX-License-Identifier: MIT

/// Mouse button. `nil` on a ``MouseEvent`` for `move`/`scroll` actions
/// where no button is involved.
public enum MouseButton: String, Sendable, Codable, Hashable {
    /// Primary (left) button.
    case left
    /// Middle button (wheel click).
    case middle
    /// Secondary (right) button.
    case right
}

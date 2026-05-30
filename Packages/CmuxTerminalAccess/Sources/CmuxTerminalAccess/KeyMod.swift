// SPDX-License-Identifier: MIT

/// Keyboard modifier flag carried by a ``KeyEvent``.
public enum KeyMod: String, Sendable, Codable, Hashable, CaseIterable {
    /// Control modifier.
    case ctrl
    /// Alt / Option modifier.
    case alt
    /// Shift modifier.
    case shift
    /// Command / Meta / Super modifier.
    case cmd
}

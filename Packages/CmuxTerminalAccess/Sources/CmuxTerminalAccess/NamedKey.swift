// SPDX-License-Identifier: MIT

/// Semantic key identity. ``char(_:)`` covers printable single
/// characters; named cases cover keys with no literal byte form.
public enum NamedKey: Hashable, Sendable {
    /// A single printable character keypress.
    case char(Character)
    /// Enter / Return key.
    case enter
    /// Tab key.
    case tab
    /// Escape key.
    case escape
    /// Space bar.
    case space
    /// Backspace key.
    case backspace
    /// Forward-delete key.
    case delete
    /// Up arrow.
    case up
    /// Down arrow.
    case down
    /// Left arrow.
    case left
    /// Right arrow.
    case right
    /// Home key.
    case home
    /// End key.
    case end
    /// Page Up key.
    case pageUp
    /// Page Down key.
    case pageDown
    /// Function key F1–F24 (1-based).
    case f(Int)
}

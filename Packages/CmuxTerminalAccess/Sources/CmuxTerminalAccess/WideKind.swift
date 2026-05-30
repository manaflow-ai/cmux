// SPDX-License-Identifier: MIT

/// East-Asian-Width / spacer state for a cell, from ghostty's
/// `vt/screen.h:82-95` four-state enum.
public enum WideKind: String, Sendable, Codable, Hashable {
    /// Narrow (single column) cell.
    case narrow
    /// Wide (two-column) cell.
    case wide
    /// Trailing spacer cell that pairs with a preceding ``wide`` cell.
    case spacerTail = "spacer_tail"
    /// Leading spacer cell that pairs with a following ``wide`` cell.
    case spacerHead = "spacer_head"
}

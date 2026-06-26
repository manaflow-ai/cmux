/// Maps numbered workspace keyboard shortcuts (e.g. Cmd-1 … Cmd-9) to workspace
/// indices for a workspace list of a known size.
///
/// Digits 1…8 target the fixed zero-based index `digit - 1`; digit 9 always
/// targets the last workspace. The mapper is a pure value parameterized by the
/// current `workspaceCount`, so one instance answers both directions: the
/// shortcut-digit-to-index lookup (when a number shortcut fires) and the
/// index-to-digit badge lookup (when rendering the per-row hint).
public struct WorkspaceShortcutMapper: Equatable, Sendable {
    /// The number of workspaces the shortcuts map across.
    public let workspaceCount: Int

    /// Creates a mapper for a workspace list of `workspaceCount` workspaces.
    public init(workspaceCount: Int) {
        self.workspaceCount = workspaceCount
    }

    /// Maps a numbered workspace shortcut digit to a zero-based workspace index.
    /// 1…8 target fixed indices; 9 always targets the last workspace. Returns
    /// `nil` when there are no workspaces or the digit has no matching index.
    public func workspaceIndex(forDigit digit: Int) -> Int? {
        guard workspaceCount > 0 else { return nil }
        guard (1...9).contains(digit) else { return nil }

        if digit == 9 {
            return workspaceCount - 1
        }

        let index = digit - 1
        return index < workspaceCount ? index : nil
    }

    /// Returns the primary digit badge to display for a workspace row.
    /// Picks the lowest digit that maps to that row index.
    public func digitForWorkspace(at index: Int) -> Int? {
        guard index >= 0 && index < workspaceCount else { return nil }
        for digit in 1...9 {
            if workspaceIndex(forDigit: digit) == index {
                return digit
            }
        }
        return nil
    }
}

import Foundation

enum WorkspaceShortcutMapper {
    /// Maps numbered workspace shortcuts to a zero-based workspace index.
    /// 1...8 target fixed indices; 9 always targets the last workspace.
    static func workspaceIndex(forDigit digit: Int, workspaceCount: Int) -> Int? {
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
    static func digitForWorkspace(at index: Int, workspaceCount: Int) -> Int? {
        guard index >= 0 && index < workspaceCount else { return nil }
        for digit in 1...9 {
            if workspaceIndex(forDigit: digit, workspaceCount: workspaceCount) == index {
                return digit
            }
        }
        return nil
    }

    static func workspaceId(forDigit digit: Int, workspaceIds: [UUID]) -> UUID? {
        guard let index = workspaceIndex(forDigit: digit, workspaceCount: workspaceIds.count) else {
            return nil
        }
        return workspaceIds[index]
    }

    static func digitForWorkspace(id workspaceId: UUID, workspaceIds: [UUID]) -> Int? {
        guard let index = workspaceIds.firstIndex(of: workspaceId) else { return nil }
        return digitForWorkspace(at: index, workspaceCount: workspaceIds.count)
    }
}

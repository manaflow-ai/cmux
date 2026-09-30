import Foundation

extension WindowRegistry {
    /// The workspace a window should show after its membership changed from
    /// `previous` to `members`. The selection belongs to the window's
    /// `WindowState`; this only repairs it:
    /// - `preferred` (workspaces just moved in by the user) wins,
    /// - a selection that is still a member stays,
    /// - a selection that left falls to its next surviving neighbor in the
    ///   old order, then the previous one, then the first member,
    /// - no members: nil (only for a window being removed; a registered
    ///   window always has one).
    static func repairedSelection(current: String?, previous: [String], members: [String], preferred: [String] = []) -> String? {
        if let pick = preferred.first(where: members.contains) { return pick }
        guard let current else { return members.first }
        if members.contains(current) { return current }
        if let index = previous.firstIndex(of: current) {
            let next = previous[index...].dropFirst().first(where: members.contains)
            let before = previous[..<index].last(where: members.contains)
            if let pick = next ?? before { return pick }
        }
        return members.first
    }
}

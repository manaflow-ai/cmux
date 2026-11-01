import CmuxNextDesign
import CmuxNextIcons
import Foundation

/// What a workspace's agents run below their turns, as the hover card says it (Leo 2026-11-01:
/// "e.g. this hover preview being able to see the # of associated subagents and whatnot would be
/// a lot more useful / like the details aren't even very useful"). acpmux counts them
/// (`subagentsRunning`, `subagentNames`, `commandsRunning` on each chat's summary); the card only
/// words them. Pure.
enum WorkspaceHoverCardWork {
    /// How the expanded card shows the running work. The gallery shows all three
    /// (`WorkspaceHoverCardGallery`); `shipped` is the one the app draws.
    enum Style: String, CaseIterable, Sendable {
        /// A count line, then one line per running subagent, named (the shipped one).
        case list
        /// The count line alone.
        case summary
        /// One line: the count, then the names after it, wrapped to two lines.
        case inline
    }

    /// The style the card draws: each subagent named on its own line, so the person sees what
    /// runs, not only how much; a count alone says little more than the spinner.
    static let shipped = Style.list

    /// The fact kind of the count line and of a subagent's line.
    static let countKind = "runningWork"
    static let subagentKind = "runningSubagent"

    /// "3 subagents · 1 command"; nil when nothing runs.
    static func counts(subagents: Int, commands: Int) -> String? {
        let parts = [subagents > 0 ? Strings.subagentsRunning(subagents) : nil,
                     commands > 0 ? Strings.commandsRunning(commands) : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: WorkspaceRowContent.separator)
    }

    /// A tab row's second line: its chat's counts first (they never cut), then its folder.
    static func tabCaption(_ tab: SidebarTab) -> String? {
        let folder = tab.folder.flatMap { $0.isEmpty ? nil : $0 }
        let parts = [counts(subagents: tab.subagentsRunning, commands: tab.commandsRunning), folder].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: WorkspaceRowContent.separator)
    }

    /// The expanded card's lines for `detail`'s running work in `style`; none when nothing runs.
    static func facts(_ detail: SidebarWorkspaceDetail, style: Style = shipped) -> [WorkspaceHoverCardContent.Fact] {
        typealias Fact = WorkspaceHoverCardContent.Fact
        guard let count = counts(subagents: detail.subagentsRunning, commands: detail.commandsRunning) else { return [] }
        // Each name once, in acpmux's order (oldest first); a nameless subagent only counts.
        var seen = Set<String>()
        let names = detail.subagentNames.filter { !$0.isEmpty && seen.insert($0).inserted }
        let head = Fact(icon: .appSampleRunningagents, text: count, kind: countKind)
        switch style {
        case .summary:
            return [head]
        case .inline:
            guard !names.isEmpty else { return [head] }
            return [Fact(icon: .appSampleRunningagents, text: count + ": " + names.joined(separator: ", "), lines: 2, kind: countKind)]
        case .list:
            // The list's own header names the kind, so each line is the name alone, by its icon.
            return [head] + names.map { Fact(icon: .agentActivity, text: $0, kind: subagentKind) }
        }
    }
}

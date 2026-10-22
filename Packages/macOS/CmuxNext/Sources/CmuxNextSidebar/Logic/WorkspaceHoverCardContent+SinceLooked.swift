import Foundation

extension WorkspaceHoverCardContent {
    /// The fact kind of the "Since you looked" line.
    static let sinceLookedKind = "sinceLooked"

    /// What the workspace's agents did after `looked` (`SidebarLookedStore`), from its history:
    /// "Since you looked: Done: 3 · Asked: 1 · Failed: 1". Nil when nothing happened since.
    static func sinceLooked(_ timeline: [SidebarTimelineEntry], after looked: Date) -> String? {
        let since = timeline.filter { $0.date > looked }
        let count = { (kind: SidebarTimelineEntry.Kind) in since.filter { $0.kind == kind }.count }
        let parts = [(count(.finished), Strings.sinceLookedDone), (count(.waiting), Strings.sinceLookedAsked),
                     (count(.failed), Strings.sinceLookedFailed)]
            .compactMap { count, word in count > 0 ? word(count) : nil }
        return parts.isEmpty ? nil : Strings.sinceLooked(parts.joined(separator: WorkspaceRowContent.separator))
    }
}

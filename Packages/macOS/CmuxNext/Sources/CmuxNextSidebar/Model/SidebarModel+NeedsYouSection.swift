import Foundation

/// The Needs you section's rows as Rust picked them at one `sectionsRevision` (`SidebarModel.needsYouRows`): the places
/// of the rows drawn, so a later read takes each row's content now (a row patch moves no row and keeps the revision).
struct SidebarNeedsYouCache {
    struct Key: Equatable {
        var revision: UInt64
        var includesWorking: Bool
        var expanded: Bool
    }

    struct Place {
        var path: SidebarRowIndex.Path
        var section: SectionID
    }

    var key: Key
    /// The rows drawn, in Rust's order (yellow, then blue, then running with Include Working).
    var drawn: [Place]
    /// Rows behind "N more" (0 expanded).
    var more: Int
    /// Rows behind "N more" were the section not expanded: whether "Show less" draws.
    var moreWhenFolded: Int
}

extension SidebarModel {
    /// The states a row lists in Needs you by (`RustSidebarCaps.Flags.of`): waiting on you (yellow), finished unread
    /// (blue), and running with Include Working.
    static func needsYouState(_ ws: SidebarWorkspace, _ caps: SidebarProjectCapsPreferences) -> RustSidebarCaps.Flags {
        var states: RustSidebarCaps.Flags = [.waiting, .unread]
        if caps.includesWorking { states.insert(.running) }
        return RustSidebarCaps.Flags.of(ws).intersection(states)
    }

    /// The Needs you section (Leo 2026-11-10: "why don't we bring back the blue at the top?"), nil when its setting is
    /// off. Rust orders and caps it (`RustSidebarCaps.needsYou`); this passes only the rows that are yellow or blue (or
    /// running, with Include Working), never the quiet ones. The answer is cached by `sectionsRevision`: a row that
    /// turns yellow or blue moves the revision (`movesRows`), and a read between costs the drawn rows only.
    func needsYouRows() -> SidebarNeedsYouRows? {
        guard projectCaps.needsYouSection else {
            needsYouCache = nil
            return nil
        }
        let key = SidebarNeedsYouCache.Key(revision: sectionsRevision, includesWorking: projectCaps.includesWorking,
                                           expanded: needsYouExpanded)
        let cache = needsYouCache?.key == key ? needsYouCache : makeNeedsYouCache(key)
        needsYouCache = cache
        guard let cache else { return nil }
        let sections = self.sections
        let entries = cache.drawn.map {
            SidebarNeedsYouRows.Entry(workspace: SidebarRowIndex.workspace(at: $0.path, in: sections), section: $0.section)
        }
        return SidebarNeedsYouRows(entries: entries, more: cache.more, isExpanded: key.expanded && cache.moreWhenFolded > 0,
                                   isFolded: needsYouFolded)
    }

    private func makeNeedsYouCache(_ key: SidebarNeedsYouCache.Key) -> SidebarNeedsYouCache? {
        SidebarPerfCounters.add(.needsYouBuilds)
        // Every listed row once, in the order the model lists them: loose rows and each group's members in place.
        var active: [(place: SidebarNeedsYouCache.Place, flags: RustSidebarCaps.Flags)] = []
        var seen: Set<WorkspaceID> = []
        let caps = projectCaps
        func consider(_ ws: SidebarWorkspace, _ path: SidebarRowIndex.Path, _ section: SectionID) {
            // A row still being made, or archived (out of the lists), is not waiting on you here.
            guard ws.rowState != .placeholder, !ws.isArchived else { return }
            let flags = Self.needsYouState(ws, caps)
            guard !flags.isEmpty, seen.insert(ws.id).inserted else { return }
            active.append((SidebarNeedsYouCache.Place(path: path, section: section), flags))
        }
        for (s, section) in sections.enumerated() {
            for (n, node) in section.nodes.enumerated() {
                switch node {
                case let .workspace(ws):
                    consider(ws, SidebarRowIndex.Path(section: s, node: n, member: nil), section.id)
                case let .group(group):
                    for (m, ws) in group.workspaces.enumerated() {
                        consider(ws, SidebarRowIndex.Path(section: s, node: n, member: m), section.id)
                    }
                case .item:
                    continue
                }
            }
        }
        guard !active.isEmpty else { return SidebarNeedsYouCache(key: key, drawn: [], more: 0, moreWhenFolded: 0) }
        let rows = active.enumerated().map { (position: $0.offset, flags: $0.element.flags) }
        // Folded to its first rows (Rust's limit, 0: three), and, expanded, every row.
        guard let first = RustSidebarCaps.needsYou(rows, includeWorking: key.includesWorking) else { return nil }
        var answer = first
        if key.expanded, first.more > 0 {
            guard let all = RustSidebarCaps.needsYou(rows, includeWorking: key.includesWorking, limit: rows.count) else { return nil }
            answer = all
        }
        return SidebarNeedsYouCache(key: key, drawn: answer.rows.map { active[$0].place }, more: answer.more,
                                    moreWhenFolded: first.more)
    }
}

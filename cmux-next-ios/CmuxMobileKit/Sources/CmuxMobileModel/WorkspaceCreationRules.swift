import Foundation
#if os(iOS)
import CmuxMobileLinkFFI
#endif

/// The New Workspace rules, which are Rust's `workspace_creation` (cmux-mobile-link-ffi): the
/// folders it offers, what a plain tap starts and where, which folders an agent chat may start
/// in, the optimistic row's title, and where a New Tab row puts the tab. This maps Swift's types
/// in and out; the Rust tests hold every case.
///
/// The portable kit also runs on macOS and Linux, which do not link the iOS framework.
/// Those hosts retain the original rules and run the same model tests.
enum WorkspaceCreationRules {
    #if os(iOS)
    private static func choices(_ options: WorkspaceCreationOptions) -> WorkspaceCreationChoices {
        WorkspaceCreationChoices(directories: options.directories, agents: options.agents, browser: options.browser,
                                 tapUsesLastDirectory: options.tapUsesLastDirectory)
    }

    private static func rust(_ start: NewWorkspaceStart) -> WorkspaceStart {
        switch start {
        case .terminal: .terminal
        case .agent(let harness): .agent(harness: harness)
        case .browser: .browser
        }
    }

    private static func swift(_ start: WorkspaceStart) -> NewWorkspaceStart {
        switch start {
        case .terminal: .terminal
        case .agent(let harness): .agent(harness)
        case .browser: .browser
        }
    }

    private static func slot(_ position: NewTabPosition) -> NewTabSlot {
        switch position {
        case .sameKind: .sameKind
        case .afterCurrent: .afterCurrent
        case .start: .start
        case .end: .end
        }
    }
    #endif

    /// The phone's recent folders on a Mac after a workspace was made in `directory`.
    static func noted(_ directory: String, in recents: [String]) -> [String] {
        #if os(iOS)
        workspaceRecentsNoted(recents: recents, directory: directory)
        #else
        var list = recents.filter { $0 != directory }
        list.insert(directory, at: 0)
        return Array(list.prefix(RecentDirectories.limit))
        #endif
    }

    /// The folders New Workspace offers: this phone's recents, then the Mac's open folders.
    static func recentDirectories(_ options: WorkspaceCreationOptions, used: [String], seen: [String]) -> [String] {
        #if os(iOS)
        workspaceRecentDirectories(directories: options.directories, used: used, seen: seen)
        #else
        guard options.directories else { return [] }
        var result: [String] = []
        for directory in used + seen where !result.contains(directory) {
            result.append(directory)
        }
        return Array(result.prefix(RecentDirectories.limit))
        #endif
    }

    /// What a plain tap on New Workspace makes on a Mac.
    static func tapStart(_ options: WorkspaceCreationOptions, used: [String], seen: [String]) -> NewWorkspaceTap {
        #if os(iOS)
        let tap = workspaceTapStart(choices: choices(options), used: used, seen: seen)
        return NewWorkspaceTap(start: swift(tap.start), directory: tap.directory)
        #else
        let terminal = NewWorkspaceTap(start: .terminal, directory: nil)
        guard let harness = options.agents.contains("") ? "" : options.agents.first else { return terminal }
        // The folders used from this phone first, then the Mac's by activity; only one open on the
        // Mac now counts, so a closed recent folder never hides an open one.
        let open = Set(seen)
        guard options.directories,
              let folder = (used + seen).first(where: { open.contains($0) && Self.isProjectFolder($0) }) else {
            return terminal
        }
        return NewWorkspaceTap(start: .agent(harness), directory: folder)
        #endif
    }

    /// Whether an agent chat may start in `path` (not the home folder or above it).
    static func isProjectFolder(_ path: String) -> Bool {
        #if os(iOS)
        workspaceIsProjectFolder(path: path)
        #else
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/").map(String.init)
        if parts.isEmpty || parts == ["~"] { return false }
        if trimmed.hasPrefix("/") {
            if parts == ["var"] || parts == ["var", "root"] { return false }
            if parts.first == "Users", parts.count <= 2, parts.last != "Shared" { return false }
        }
        return true
        #endif
    }

    /// The folder a plain tap uses: the last used, else home; nil when the Mac picks.
    static func defaultDirectory(_ options: WorkspaceCreationOptions, used: [String]) -> String? {
        #if os(iOS)
        workspaceDefaultDirectory(choices: choices(options), used: used)
        #else
        guard options.directories, options.tapUsesLastDirectory else { return nil }
        return used.first ?? "~"
        #endif
    }

    /// Whether the Mac can start a workspace this way.
    static func offers(_ start: NewWorkspaceStart, _ options: WorkspaceCreationOptions) -> Bool {
        #if os(iOS)
        workspaceStartOffered(choices: choices(options), start: rust(start))
        #else
        switch start {
        case .terminal: true
        case .agent(let harness): options.agents.contains(harness)
        case .browser: options.browser
        }
        #endif
    }

    /// The optimistic row's title, unique among the Mac's titles.
    static func placeholderTitle(directory: String?, existing: [String]) -> String {
        #if os(iOS)
        workspacePlaceholderTitle(directory: directory, existing: existing)
        #else
        let last = directory.map { ($0 as NSString).lastPathComponent } ?? ""
        let base = directory == "/" || last.isEmpty || last == "~" ? "New Workspace" : last
        return uniqueTitle(base, existing: existing)
        #endif
    }

    /// "cmux", then "cmux 2", "cmux 3", …
    static func uniqueTitle(_ base: String, existing: [String]) -> String {
        #if os(iOS)
        workspaceUniqueTitle(base: base, existing: existing)
        #else
        let taken = Set(existing)
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
        #endif
    }

    /// The optimistic agent tab's title for a harness.
    static func agentTabTitle(_ harness: String) -> String {
        #if os(iOS)
        workspaceAgentTabTitle(harness: harness)
        #else
        harness.isEmpty ? "Agent Chat" : harness.capitalized
        #endif
    }

    /// The `move-tab` index for a New Tab row; nil when the tab is in place.
    static func moveIndex(_ position: NewTabPosition, from: Int, anchor: Int, pinned: [Bool], groups: [String?]) -> Int? {
        #if os(iOS)
        guard from >= 0, anchor >= 0 else { return nil }
        return newTabMoveIndex(slot: slot(position), from: UInt32(clamping: from), anchor: UInt32(clamping: anchor),
                               pinned: pinned, groups: groups).map(Int.init)
        #else
        let count = pinned.count
        guard count > 1, pinned.indices.contains(from), pinned.indices.contains(anchor), anchor != from else { return nil }
        // The places without the new tab, where the final index is counted.
        let others = pinned.indices.filter { $0 != from }
        let pinnedCount = others.prefix { pinned[$0] }.count
        let final: Int
        switch position {
        case .sameKind, .afterCurrent:
            guard var at = others.firstIndex(of: anchor) else { return nil }
            if groups.indices.contains(anchor), let group = groups[anchor] {
                while at + 1 < others.count, groups.indices.contains(others[at + 1]), groups[others[at + 1]] == group { at += 1 }
            }
            final = max(at + 1, pinnedCount)
        case .start: final = pinnedCount
        case .end: final = count - 1
        }
        let clamped = min(max(final, 0), count - 1)
        guard clamped != from else { return nil }
        return clamped > from ? clamped + 1 : clamped
        #endif
    }
}

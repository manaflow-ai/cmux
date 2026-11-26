import Foundation
#if os(iOS)
import CmuxMobileLinkFFI
#endif

/// The New Workspace rules, which are Rust's `workspace_creation` (cmux-mobile-link-ffi): the
/// folders it offers, what a plain tap starts and where, which folders an agent chat may start
/// in, the optimistic row's title, and where a New Tab row puts the tab. This maps Swift's types
/// in and out; the Rust tests hold every case.
///
/// The Rust library links only on iOS. The macOS kit test host gets plain answers (a terminal
/// in the Mac's folder, no recents, "New Workspace", nothing moved), and the tests of these
/// rules run on the iOS simulator.
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
        [directory]
        #endif
    }

    /// The folders New Workspace offers: this phone's recents, then the Mac's open folders.
    static func recentDirectories(_ options: WorkspaceCreationOptions, used: [String], seen: [String]) -> [String] {
        #if os(iOS)
        workspaceRecentDirectories(directories: options.directories, used: used, seen: seen)
        #else
        []
        #endif
    }

    /// What a plain tap on New Workspace makes on a Mac.
    static func tapStart(_ options: WorkspaceCreationOptions, used: [String], seen: [String]) -> NewWorkspaceTap {
        #if os(iOS)
        let tap = workspaceTapStart(choices: choices(options), used: used, seen: seen)
        return NewWorkspaceTap(start: swift(tap.start), directory: tap.directory)
        #else
        NewWorkspaceTap(start: .terminal, directory: nil)
        #endif
    }

    /// Whether an agent chat may start in `path` (not the home folder or above it).
    static func isProjectFolder(_ path: String) -> Bool {
        #if os(iOS)
        workspaceIsProjectFolder(path: path)
        #else
        false
        #endif
    }

    /// The folder a plain tap uses: the last used, else home; nil when the Mac picks.
    static func defaultDirectory(_ options: WorkspaceCreationOptions, used: [String]) -> String? {
        #if os(iOS)
        workspaceDefaultDirectory(choices: choices(options), used: used)
        #else
        nil
        #endif
    }

    /// Whether the Mac can start a workspace this way.
    static func offers(_ start: NewWorkspaceStart, _ options: WorkspaceCreationOptions) -> Bool {
        #if os(iOS)
        workspaceStartOffered(choices: choices(options), start: rust(start))
        #else
        true
        #endif
    }

    /// The optimistic row's title, unique among the Mac's titles.
    static func placeholderTitle(directory: String?, existing: [String]) -> String {
        #if os(iOS)
        workspacePlaceholderTitle(directory: directory, existing: existing)
        #else
        "New Workspace"
        #endif
    }

    /// "cmux", then "cmux 2", "cmux 3", …
    static func uniqueTitle(_ base: String, existing: [String]) -> String {
        #if os(iOS)
        workspaceUniqueTitle(base: base, existing: existing)
        #else
        base
        #endif
    }

    /// The optimistic agent tab's title for a harness.
    static func agentTabTitle(_ harness: String) -> String {
        #if os(iOS)
        workspaceAgentTabTitle(harness: harness)
        #else
        "Agent Chat"
        #endif
    }

    /// The `move-tab` index for a New Tab row; nil when the tab is in place.
    static func moveIndex(_ position: NewTabPosition, from: Int, anchor: Int, pinned: [Bool], groups: [String?]) -> Int? {
        #if os(iOS)
        guard from >= 0, anchor >= 0 else { return nil }
        return newTabMoveIndex(slot: slot(position), from: UInt32(clamping: from), anchor: UInt32(clamping: anchor),
                               pinned: pinned, groups: groups).map(Int.init)
        #else
        nil
        #endif
    }
}

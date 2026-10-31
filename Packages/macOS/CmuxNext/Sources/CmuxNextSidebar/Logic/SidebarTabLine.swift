public import CmuxNextDesign
import Foundation

/// How a listed tab row (Lawrence's f32ee25f, `sidebar.showWorkspaceTabs`) reads (Leo 2026-10-27: "look at
/// what's redundant and look at what's useful ... not only does it show, well, you have Claude running here and
/// another Claude running there, and they're both titled this and that, but also ... a little bit more metadata").
public nonisolated enum SidebarTabLineLook: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The tab's own title only, as before.
    case plain
    /// Repeats dropped: no bare "~", no workspace name again; the tab's status mark.
    case clean
    /// `clean`, the agent's mark, and one quiet detail after the name: the program's status words, the
    /// agent, the page's host or the folder (the default).
    case detail
    /// The program's status words lead when it reports any; the name follows, quieter.
    case statusFirst

    public var tunableTitle: String {
        switch self {
        case .plain: "Title only"
        case .clean: "Without repeats"
        case .detail: "Name, then details"
        case .statusFirst: "Status words first"
        }
    }

    /// The look draws the tab's status mark and its agent's mark.
    var drawsMarks: Bool { self != .plain }
}

/// What one listed tab row says: its name and a quieter detail after it.
struct SidebarTabLine: Equatable {
    var name: String
    var detail: String?

    /// `tab` in `look`, without repeating its workspace's name (`SidebarTab.workspaceName`). `terminalName`
    /// names a terminal whose title says nothing of its own ("Terminal"); another tab keeps its title then.
    static func make(_ tab: SidebarTab, look: SidebarTabLineLook, terminalName: String) -> SidebarTabLine {
        let workspace = tab.workspaceName ?? ""
        guard look != .plain else { return SidebarTabLine(name: tab.title, detail: nil) }
        let isTerminal = tab.kind == .terminal || tab.kind == .remoteTerminal
        let name = cleanName(tab, workspace: workspace) ?? tab.agent ?? (isTerminal ? terminalName : tab.title)
        guard look != .clean else { return SidebarTabLine(name: name, detail: nil) }
        if look == .statusFirst, let words = tab.words?.nonEmpty {
            return SidebarTabLine(name: words, detail: fold(words) == fold(name) ? nil : name)
        }
        // The first fact the name and the workspace row do not already say, most telling first; a bare
        // "~" says nothing.
        let said = Set([name, workspace].map(fold))
        let facts = [tab.words, tab.agent, tab.host, tab.folder == "~" || tab.sharesWorkspaceFolder ? nil : tab.folder]
        return SidebarTabLine(name: name, detail: facts.lazy.compactMap { $0?.nonEmpty }.first { !said.contains(fold($0)) })
    }

    /// The tab's title without what the row above already says; nil when nothing is left: a bare folder
    /// ("~", the shell's untitled default), the workspace's own name, or only the workspace's name with a
    /// host or session before or after it, which keeps that host ("gcp-codex-lane-1/rail-jump-final" under
    /// rail-jump-final reads "gcp-codex-lane-1").
    static func cleanName(_ tab: SidebarTab, workspace: String) -> String? {
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title == "~" { return nil }
        // A cwd-derived title is the existing terminal title source. Keep a
        // non-home folder visible so sibling terminals remain distinguishable.
        if title == tab.folder { return title == "~" ? nil : title }
        let ws = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ws.isEmpty else { return title }
        if fold(title) == fold(ws) { return nil }
        for separator in ["/", ":", " · ", " - ", " — "] {
            if title.lowercased().hasSuffix((separator + ws).lowercased()) {
                let rest = String(title.dropLast(separator.count + ws.count)).trimmingCharacters(in: .whitespaces)
                return rest.isEmpty ? nil : rest
            }
            if title.lowercased().hasPrefix((ws + separator).lowercased()) {
                let rest = String(title.dropFirst(ws.count + separator.count)).trimmingCharacters(in: .whitespaces)
                return rest.isEmpty ? nil : rest
            }
        }
        return title
    }

    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private extension String {
    var nonEmpty: String? {
        let text = trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

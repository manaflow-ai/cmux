public import CmuxNextDaemon
import Foundation

/// An agent chat names its row over an idle shell beside it (Leo, 2026-10-28: "we don't want to just be
/// seeing these bare terminals. It's weird to have that be the thing that's showing. I'd rather just see
/// the other thing instead of that, you know, tilde.").
extension SidebarMapping {
    /// Shell names a terminal reports as its title while idle (`NewWorkspaceName`'s list).
    static let bareShells: Set<String> = ["zsh", "bash", "fish", "sh", "nu", "dash", "ksh", "tcsh", "pwsh", "login", "~"]

    /// The tab a row and its window's titlebar are named for: `front`, unless it is an idle shell or a New
    /// Tab page (`newTabPages`) while the workspace has an agent chat; then that chat (a working or waiting
    /// one first, as `agentTab` picks).
    public func labelTab(_ front: TabModel?, _ tabs: [TabModel], newTabPages: Set<String> = []) -> TabModel? {
        guard let front, isIdle(front, newTabPages: newTabPages) else { return front }
        let chats = tabs.lazy.filter { $0.agentSession != nil && !newTabPages.contains($0.id) }
        return chats.first { $0.agent?.state == .working || $0.agent?.state == .blocked } ?? chats.first ?? front
    }

    /// A New Tab page, or a terminal with no agent and no running command (its shell integration's
    /// `commandSinceMs`, its title's activity) whose title is empty, a bare shell or its own folder.
    func isIdle(_ tab: TabModel, newTabPages: Set<String>) -> Bool {
        if newTabPages.contains(tab.id) { return true }
        guard tab.kind == .pty, tab.agent == nil, tab.commandSinceMs == nil, tab.titleActivity == nil else { return false }
        let title = tab.titleText.trimmingCharacters(in: .whitespaces)
        if title.isEmpty || Self.bareShells.contains(title.hasPrefix("-") ? String(title.dropFirst()) : title) { return true }
        return tab.cwd.map { title == $0 || title == abbreviate($0) } == true
    }

    /// The first tab that reports a folder: the row's folder and branch. While `label` (the row's
    /// `labelTab`) is a chat, an idle shell at home gives none: its "~" never names the row.
    func folderTab(_ tabs: [TabModel], label: TabModel? = nil) -> TabModel? {
        let chat = label?.agentSession != nil
        return tabs.first { tab in
            guard let cwd = tab.cwd else { return false }
            return !chat || !(isIdle(tab, newTabPages: []) && abbreviate(cwd) == "~")
        }
    }
}

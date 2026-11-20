public import CmuxNextDaemon
import Foundation
public import Observation

/// The title a Cloud chat start lends its tabs (2026-11-10: a Cloud chat's row read "workspace-6" with no cloud mark
/// and its tab "New Tab" while the start ran). From the Send, the New Tab page that sent reads as the chat it starts:
/// its tab and its workspace's row take the prompt's gist, as a local chat's do from its first prompt, and the row
/// draws the cloud mark (``SidebarMapping/PageFace/startsInCloud``). Once the chat opens on its machine the title moves
/// to that chat's tab, which keeps it until its chat has a title of its own on this Mac.
///
/// Each tab is held weakly by its record's identity: a closed tab's entry never names a later tab.
/// The app owns one (`AppServices.cloudStartTitles`): the start's runner writes it, the tab strip, the sidebar row
/// and the workspace name read it.
@MainActor @Observable
public final class AgentCloudStartTitles {
    private struct Entry {
        weak var tab: TabModel?
        let title: String
        /// The start failed (``fail(_:machine:)``): the page still reads as the Cloud chat it tried to start.
        var failed = false
        /// The Cloud machine a failed start took, as its list names it; nil when it failed before it had one.
        var machine: String?
    }

    private var titles: [ObjectIdentifier: Entry] = [:]
    /// New Cloud Chat's own workspaces (cmux#45947): each row reads as Cloud from the click, before a Send names its chat.
    private var cloudWorkspaces: Set<String> = []

    public init() {}

    /// The title `tab` reads while it starts a Cloud chat, shows the chat one started, or reads after its start failed;
    /// nil for any other tab.
    public func title(of tab: TabModel) -> String? {
        entry(of: tab)?.title
    }

    /// Whether `tab` is a New Tab page whose Send is starting a Cloud chat (or a chat one started, or one whose start
    /// failed: cmux#47678, a failed Cloud start read as a plain local page and nothing said it was Cloud's).
    public func startsInCloud(_ tab: TabModel) -> Bool { entry(of: tab) != nil }

    /// What a failed start of `tab` says of its machine: nil while its start runs, after it opened, or for any other
    /// tab; `.some(nil)` for a start that failed before it had a machine.
    public func failedStart(of tab: TabModel) -> String?? {
        guard let entry = entry(of: tab), entry.failed else { return nil }
        return .some(entry.machine)
    }

    /// The entry of `tab`; a failed start's only while its page has no chat session of its own (a local one sent after it).
    private func entry(of tab: TabModel) -> Entry? {
        guard let entry = titles[ObjectIdentifier(tab)], entry.tab === tab else { return nil }
        return entry.failed && tab.agentSession?.session != nil ? nil : entry
    }

    /// Whether workspace `id` is one New Cloud Chat opened for its chat (``beginWorkspace(_:)``), until its start ends.
    public func startsInCloud(workspace id: String) -> Bool { cloudWorkspaces.contains(id) }

    /// New Cloud Chat opened workspace `id` for its chat: its row draws the cloud mark from now.
    public func beginWorkspace(_ id: String) { cloudWorkspaces.insert(id) }

    /// The start in workspace `id` ended: on its machine the chat has a row of its own, and on this Mac it is a local chat.
    public func endWorkspace(_ id: String?) { if let id, cloudWorkspaces.contains(id) { cloudWorkspaces.remove(id) } }

    /// The Send of `tab` starts a Cloud chat whose first prompt is `task`; `untitled` when it names nothing (only attachments).
    public func begin(_ tab: TabModel, task: String, untitled: String) {
        titles = titles.filter { $0.value.tab != nil }
        titles[ObjectIdentifier(tab)] = Entry(tab: tab, title: Self.title(task: task) ?? untitled)
    }

    /// The start of `tab` ended (refused or handed over): it reads as its page again.
    public func end(_ tab: TabModel) {
        if titles[ObjectIdentifier(tab)] != nil { titles[ObjectIdentifier(tab)] = nil }
    }

    /// The start of `tab` failed on `machine` (its list's name; nil before it had one): the page keeps the start's title
    /// and the cloud mark, and its row names the machine, until a Retry begins it again or the page starts a chat of its
    /// own (cmux#47678).
    public func fail(_ tab: TabModel, machine: String?) {
        guard var entry = titles[ObjectIdentifier(tab)], entry.tab === tab else { return }
        entry.failed = true
        entry.machine = machine.flatMap { $0.isEmpty ? nil : $0 }
        titles[ObjectIdentifier(tab)] = entry
    }

    /// The start of `tab` ended: one that `opened` (or ran on this Mac instead) reads as its page again; one that failed
    /// keeps reading as a Cloud chat on `machine` (``fail(_:machine:)``, cmux#47678).
    public func ended(_ tab: TabModel, opened: Bool, machine: String?) {
        if opened { end(tab) } else { fail(tab, machine: machine) }
    }

    /// The chat opened as `opened` on its machine: it takes the title `origin` read, and `origin` ends.
    public func hand(from origin: TabModel, to opened: TabModel) {
        guard let title = title(of: origin) else { return }
        end(origin)
        titles[ObjectIdentifier(opened)] = Entry(tab: opened, title: title)
    }

    /// The title a start whose first prompt is `task` reads as: the prompt's naming line, as acpmux titles a chat by it.
    public nonisolated static func title(task: String) -> String? {
        AgentTurnStates.promptGist(task).flatMap { $0.isEmpty ? nil : $0 }
    }
}

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
    }

    private struct Mark { weak var tab: TabModel? }

    private var titles: [ObjectIdentifier: Entry] = [:]
    /// The titles handed to the chats starts opened on their machines (``hand(from:to:)``), by the chat tab's resource id
    /// (`tab_` and random hex, unique on every machine): a store that rebuilds the chat's pane makes a new record for the
    /// same tab, which keeps its title (cmux#55540). A tab with no resource id yet is held by its record only. The latest
    /// ``handedKept`` are kept; a chat open that long has its own title.
    private var handed: [String: String] = [:]
    private var handedOrder: [String] = []
    static let handedKept = 32
    /// New Tab pages whose Send started a Cloud chat (cmux#51000): marked from the Send, kept when the start fails (its
    /// page shows the failure and Retry), cleared once the chat shows in place (``CloudFrontedChats`` marks it then).
    private var cloudSends: [ObjectIdentifier: Mark] = [:]
    /// Mac tabs that show the chat their start opened in place (``opened(_:)``, `CloudFrontedChats`): each keeps its start's
    /// title, which ``title(of:showing:untitled:)`` reads until the chat has a title of its own (cmux#55540). A Mac tab is
    /// this Mac's own record, so the title holds whatever the chat's machine does to its record of the chat.
    private var inPlace: Set<ObjectIdentifier> = []
    /// New Cloud Chat's own workspaces (cmux#45947): each row reads as Cloud from the click, before a Send names its chat.
    private var cloudWorkspaces: Set<String> = []

    public init() {}

    /// The title `tab` reads while it starts a Cloud chat, or shows the chat one started; nil for any other tab.
    public func title(of tab: TabModel) -> String? {
        if let entry = titles[ObjectIdentifier(tab)], entry.tab === tab { return inPlace.contains(ObjectIdentifier(tab)) ? nil : entry.title }
        return handed.isEmpty ? nil : tab.resourceID.flatMap { handed[$0.rawValue] }
    }

    /// The start's title Mac tab `mac` keeps while it shows the chat that start opened in place; nil for any other tab.
    public func inPlaceTitle(of mac: TabModel) -> String? {
        guard !inPlace.isEmpty, inPlace.contains(ObjectIdentifier(mac)), let entry = titles[ObjectIdentifier(mac)], entry.tab === mac else { return nil }
        return entry.title
    }

    /// What Mac tab `mac`, showing Cloud chat `chat` in place, reads: its start's title (``inPlaceTitle(of:)``) until the chat has a
    /// title of its own here (a name the person gave it, its turns' title, or a title its record carries other than the blank page's
    /// or `untitled`, the chat tab's default). The chat's record read "Agent" and the tab with it (cmux#55540).
    public func title(of mac: TabModel, showing chat: TabModel, untitled: String, turns: AgentTurnStateStore = .shared) -> String? {
        guard let title = inPlaceTitle(of: mac), chat.name?.isEmpty ?? true, chat.agentSession.flatMap(turns.title(for:)) == nil else { return nil }
        let own = chat.displayTitle
        return own.isEmpty || own == untitled || TabItemMapping.isBlankPageAddress(own) ? title : nil
    }

    /// Whether `tab` is a New Tab page whose Send is starting a Cloud chat (or a chat one started).
    public func startsInCloud(_ tab: TabModel) -> Bool { title(of: tab) != nil }

    /// Whether workspace `id` is one New Cloud Chat opened for its chat (``beginWorkspace(_:)``), until its start ends.
    public func startsInCloud(workspace id: String) -> Bool { cloudWorkspaces.contains(id) }

    /// New Cloud Chat opened workspace `id` for its chat: its row draws the cloud mark from now.
    public func beginWorkspace(_ id: String) { cloudWorkspaces.insert(id) }

    /// The start in workspace `id` ended: on its machine the chat has a row of its own, and on this Mac it is a local chat.
    public func endWorkspace(_ id: String?) { if let id, cloudWorkspaces.contains(id) { cloudWorkspaces.remove(id) } }

    /// The Send of `tab` starts a Cloud chat whose first prompt is `task`; `untitled` when it names nothing (only attachments).
    public func begin(_ tab: TabModel, task: String, untitled: String) {
        titles = titles.filter { $0.value.tab != nil }
        inPlace = inPlace.filter { titles[$0] != nil && $0 != ObjectIdentifier(tab) }
        titles[ObjectIdentifier(tab)] = Entry(tab: tab, title: Self.title(task: task) ?? untitled)
        cloudSends = cloudSends.filter { $0.value.tab != nil }
        cloudSends[ObjectIdentifier(tab)] = Mark(tab: tab)
    }

    /// Whether `tab`'s Send started a Cloud chat that is starting or failed (``begin(_:task:untitled:)`` until ``opened(_:)``):
    /// its tab shows the cloud (cmux#51000). Only the tab strip reads it; the sidebar row reads ``startsInCloud(_:)``.
    public func sentToCloud(_ tab: TabModel) -> Bool { cloudSends[ObjectIdentifier(tab)]?.tab === tab }

    /// Whether `tab`, in workspace `workspace`, wears the cloud while it is a Cloud chat not yet shown in place (cmux#51000): its Send started
    /// one (``sentToCloud(_:)``), or New Cloud Chat opened its workspace for it (``startsInCloud(workspace:)``), from the click, before any Send.
    public func marksCloud(_ tab: TabModel, workspace: String?) -> Bool {
        sentToCloud(tab) || workspace.map { startsInCloud(workspace: $0) } == true
    }

    /// The person pressed Send on `tab` with Cloud picked (its gesture, before the start reaches the runner, cmux#51000): its tab wears the
    /// cloud from now, as ``begin(_:task:untitled:)`` marks it.
    public func sending(_ tab: TabModel) {
        cloudSends = cloudSends.filter { $0.value.tab != nil }
        if cloudSends[ObjectIdentifier(tab)]?.tab !== tab { cloudSends[ObjectIdentifier(tab)] = Mark(tab: tab) }
    }

    /// `tab`'s start opened its chat, which now shows in place: the front marks it from here (``sentToCloud(_:)`` ends), and
    /// the tab keeps its start's title for that chat (``inPlaceTitle(of:)``), past ``end(_:)``.
    public func opened(_ tab: TabModel) {
        if cloudSends[ObjectIdentifier(tab)] != nil { cloudSends[ObjectIdentifier(tab)] = nil }
        if titles[ObjectIdentifier(tab)]?.tab === tab { inPlace.insert(ObjectIdentifier(tab)) }
    }

    /// The start of `tab` ended (refused, failed or handed over): it reads as its page again. A tab that shows its chat in place
    /// keeps the title for that chat.
    public func end(_ tab: TabModel) {
        guard !inPlace.contains(ObjectIdentifier(tab)) else { return }
        if titles[ObjectIdentifier(tab)] != nil { titles[ObjectIdentifier(tab)] = nil }
    }

    /// The chat opened as `opened` on its machine: it takes the title `origin` reads. `origin` keeps it until its start
    /// ends (``end(_:)``, after the Mac tab shows the chat in place or closes): ending it here left the Mac tab "New Tab"
    /// and its row "workspace-NNN" while the chat's page painted (cmux#55540).
    public func hand(from origin: TabModel, to opened: TabModel) {
        guard let title = title(of: origin) else { return }
        titles[ObjectIdentifier(opened)] = Entry(tab: opened, title: title)
        guard let id = opened.resourceID?.rawValue else { return }
        if handed.updateValue(title, forKey: id) == nil { handedOrder.append(id) }
        while handedOrder.count > Self.handedKept { handed[handedOrder.removeFirst()] = nil }
    }

    /// The title a start whose first prompt is `task` reads as: the prompt's naming line, as acpmux titles a chat by it.
    public nonisolated static func title(task: String) -> String? {
        AgentTurnStates.promptGist(task).flatMap { $0.isEmpty ? nil : $0 }
    }
}

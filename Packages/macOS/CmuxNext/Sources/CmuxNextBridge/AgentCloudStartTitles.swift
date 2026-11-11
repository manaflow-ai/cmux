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
@MainActor @Observable
public final class AgentCloudStartTitles {
    /// The app's one registry: the start's runner writes it, the tab strip, the sidebar row and the workspace name read it.
    public static let shared = AgentCloudStartTitles()

    private struct Entry {
        weak var tab: TabModel?
        let title: String
    }

    private var titles: [ObjectIdentifier: Entry] = [:]

    public init() {}

    /// The title `tab` reads while it starts a Cloud chat, or shows the chat one started; nil for any other tab.
    public func title(of tab: TabModel) -> String? {
        guard let entry = titles[ObjectIdentifier(tab)], entry.tab === tab else { return nil }
        return entry.title
    }

    /// Whether `tab` is a New Tab page whose Send is starting a Cloud chat (or a chat one started).
    public func startsInCloud(_ tab: TabModel) -> Bool { title(of: tab) != nil }

    /// The Send of `tab` starts a Cloud chat whose first prompt is `task`; `untitled` when it names nothing (only attachments).
    public func begin(_ tab: TabModel, task: String, untitled: String) {
        titles = titles.filter { $0.value.tab != nil }
        titles[ObjectIdentifier(tab)] = Entry(tab: tab, title: Self.title(task: task) ?? untitled)
    }

    /// The start of `tab` ended (refused, failed or handed over): it reads as its page again.
    public func end(_ tab: TabModel) {
        if titles[ObjectIdentifier(tab)] != nil { titles[ObjectIdentifier(tab)] = nil }
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

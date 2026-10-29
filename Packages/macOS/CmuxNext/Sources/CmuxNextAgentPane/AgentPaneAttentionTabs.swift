public import CmuxNextSettings
public import Foundation

/// The tabs an agent marked as needing the person (`tab-attention-v1`, `cmux attention request`),
/// for every agent page's Needs you list (webviews `needsYou/attentionTabs.ts`). App-wide like the
/// marks: the App's ``AttentionTabsWatch`` sets ``items`` from the store and ``onOpen`` to its
/// user jump; each page gets the list at load and handshake and again on every change. A page's
/// Go to (`chat.attention.open {tabId}`) shows the tab as Search Tabs does. Leo, 2026-10-22: "idk
/// where things are man i dont see anything other than the current workspace".
@MainActor
public final class AgentPaneAttentionTabs {
    /// Makes an empty attention store. The app owns one and tests may create isolated stores.
    public init() {}

    /// The marked tabs, newest mark first.
    public var items: [Item] = [] {
        didSet {
            guard items != oldValue else { return }
            for view in views.allObjects { send(to: view) }
            onChange?()
        }
    }
    /// Shows a marked tab as a user's jump does; false when no connected machine has it.
    public var onOpen: ((String) -> Bool)?
    /// Hears each change of ``items`` (the App reloads an open Go to What Needs Me page).
    public var onChange: (() -> Void)?
    /// The pages pushed so far, held weakly, for the pushes on a change.
    private let views = NSHashTable<AgentPaneView>.weakObjects()

    /// Longest opaque request key a page may echo, in UTF-8 bytes.
    public static let maximumTabID = 256

    /// One marked tab as the page draws it.
    public nonisolated struct Item: Hashable, Sendable {
        public var tabId: String
        /// The agent's one line: what the person must do there.
        public var reason: String
        public var workspaceTitle: String
        public var tabTitle: String
        /// When the agent marked it (epoch ms, from the daemon).
        public var atMs: UInt64

        public init(tabId: String, reason: String, workspaceTitle: String, tabTitle: String, atMs: UInt64) {
            self.tabId = tabId
            self.reason = reason
            self.workspaceTitle = workspaceTitle
            self.tabTitle = tabTitle
            self.atMs = atMs
        }

        var json: JSONValue {
            [
                "kind": "tab", "tabId": .string(tabId), "reason": .string(reason),
                "workspaceTitle": .string(workspaceTitle), "tabTitle": .string(tabTitle), "atMs": .number(Double(atMs)),
            ]
        }
    }

    /// The list, read now, as a page host event; `view` then also gets every change.
    func event(for view: AgentPaneView) -> AgentPageEvent {
        views.add(view)
        return .attentionTabs(items)
    }

    /// Pushes the list, read now, to `view`'s page; `view` then also gets every change.
    func push(to view: AgentPaneView) {
        views.add(view)
        send(to: view)
    }

    private func send(to view: AgentPaneView) {
        let event = AgentPageEvent.attentionTabs(items)
        view.deliver([event], scripts: ["window.cmuxAcpmuxBridge?.applyAttentionTabs?.(\(event.value.compactText));"])
    }

    /// A page's Go to: shows `tabId` when it is a marked tab. Only a listed tab, so a page never
    /// reaches a tab it was not shown.
    public func open(_ tabId: String) -> Bool {
        guard items.contains(where: { $0.tabId == tabId }), let onOpen else { return false }
        return onOpen(tabId)
    }
}

extension AgentPageEvent {
    /// The marked tabs for Needs you (`attentionTabs`): `[{kind, tabId, reason, workspaceTitle,
    /// tabTitle, atMs}]`, newest first.
    static func attentionTabs(_ items: [AgentPaneAttentionTabs.Item]) -> AgentPageEvent {
        AgentPageEvent(kind: "attentionTabs", value: .array(items.map(\.json)))
    }
}

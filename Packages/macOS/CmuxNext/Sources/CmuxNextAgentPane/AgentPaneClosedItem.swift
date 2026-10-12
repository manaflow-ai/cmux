import CmuxNextSettings
public import Foundation

/// One recently closed tab, screen or workspace as the New Tab page's Recently Closed section
/// shows it (cx-d0d.60): the history's closed entry (`HistoryService.closedEntries`). Clicking it
/// reopens it through `tab.jump {target: "closed", id}`.
public nonisolated struct AgentPaneClosedItem: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case terminal, browser, screen, workspace
    }

    /// The history entry id (`closed:...`).
    public var id: String
    public var kind: Kind
    public var title: String
    /// URL or directory, under the title.
    public var detail: String?
    public var closedAt: Date
    /// A browser tab's favicon as a data URL.
    public var icon: String?
    /// False while its machine is not connected: shown dimmed, not clickable.
    public var isAvailable: Bool

    public init(id: String, kind: Kind, title: String, detail: String?, closedAt: Date, icon: String?, isAvailable: Bool) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.closedAt = closedAt
        self.icon = icon
        self.isAvailable = isAvailable
    }

    /// The most items one push carries (the section shows the newest few).
    public static let maximumPushed = 8

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id), "kind": .string(kind.rawValue), "title": .string(title), "available": .bool(isAvailable),
            "closedAt": .number((closedAt.timeIntervalSince1970 * 1000).rounded()),
        ]
        if let detail { object["detail"] = .string(detail) }
        if let icon { object["icon"] = .string(icon) }
        return .object(object)
    }
}

extension AgentPageEvent {
    /// The newest recently closed items for the New Tab page (`recentlyClosed`).
    public static func recentlyClosed(_ items: [AgentPaneClosedItem]) -> AgentPageEvent {
        AgentPageEvent(kind: "recentlyClosed", value: .array(items.prefix(AgentPaneClosedItem.maximumPushed).map(\.json)))
    }
}

extension AgentPaneClosedItem {
    /// Pushes `items` to `view`'s page (not an AgentPaneView extension: that type is at its size limit).
    @MainActor static func push(_ items: [AgentPaneClosedItem], to view: AgentPaneView) {
        let event = AgentPageEvent.recentlyClosed(items)
        view.deliver([event], scripts: ["window.cmuxAcpmuxBridge?.applyRecentlyClosed?.(\(event.value.compactText));"])
    }
}

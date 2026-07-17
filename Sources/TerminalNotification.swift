import Foundation

enum TerminalNotificationSource: Hashable, Sendable {
    case terminal
    case website(origin: URL)
}

enum TerminalNotificationTarget: Hashable, Sendable {
    case workspace(tabId: UUID)
    case global
}

struct TerminalNotification: Identifiable, Hashable, Sendable {
    let id: UUID
    let surfaceId: UUID?
    let panelId: UUID?
    let retargetsToLiveSurfaceOwner: Bool
    let title: String
    let subtitle: String
    let body: String
    let createdAt: Date
    var isRead: Bool
    var paneFlash: Bool = true
    var scrollPosition: TerminalNotificationScrollPosition?
    var clickAction: TerminalNotificationClickAction?
    let source: TerminalNotificationSource
    let target: TerminalNotificationTarget

    init(
        id: UUID,
        tabId: UUID? = nil,
        surfaceId: UUID?,
        panelId: UUID? = nil,
        retargetsToLiveSurfaceOwner: Bool = true,
        title: String,
        subtitle: String,
        body: String,
        createdAt: Date,
        isRead: Bool,
        paneFlash: Bool = true,
        scrollPosition: TerminalNotificationScrollPosition? = nil,
        clickAction: TerminalNotificationClickAction? = nil,
        source: TerminalNotificationSource = .terminal,
        target: TerminalNotificationTarget? = nil
    ) {
        self.id = id
        self.surfaceId = surfaceId
        self.panelId = panelId
        self.retargetsToLiveSurfaceOwner = retargetsToLiveSurfaceOwner
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
        self.paneFlash = paneFlash
        self.scrollPosition = scrollPosition
        self.clickAction = clickAction
        self.source = source
        self.target = target ?? tabId.map(TerminalNotificationTarget.workspace(tabId:)) ?? .global
    }

    var isGlobal: Bool { target == .global }

    var workspaceTabId: UUID? {
        guard case .workspace(let tabId) = target else { return nil }
        return tabId
    }

    /// Compatibility identity for legacy notification projections. Global
    /// notifications use their own notification id and never masquerade as a workspace.
    var tabId: UUID { workspaceTabId ?? id }

    func matches(tabId targetTabId: UUID, surfaceId targetSurfaceId: UUID?) -> Bool {
        guard workspaceTabId == targetTabId else { return false }
        guard let targetSurfaceId else {
            return surfaceId == nil && panelId == nil
        }
        return surfaceId == targetSurfaceId || panelId == targetSurfaceId
    }

    /// Matches a clear without letting live-owner expansion cross a confined notification's workspace boundary.
    func matchesClear(tabId targetTabId: UUID, liveTabId: UUID, surfaceId targetSurfaceId: UUID?) -> Bool {
        guard let workspaceTabId else { return false }
        let matchesWorkspace = workspaceTabId == targetTabId || (retargetsToLiveSurfaceOwner && workspaceTabId == liveTabId)
        return matchesWorkspace && matches(tabId: workspaceTabId, surfaceId: targetSurfaceId)
    }
}

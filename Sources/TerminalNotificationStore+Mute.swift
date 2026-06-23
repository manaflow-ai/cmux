import Foundation

extension TerminalNotificationStore {
    func activeWorkspaceNotificationMuteExpiration(forTabId tabId: UUID, now: Date = Date()) -> Date? {
        activeNotificationMuteExpiration(notificationMuteExpirationsByWorkspaceId[tabId], now: now)
    }

    func activeSurfaceNotificationMuteExpiration(forSurfaceId surfaceId: UUID, now: Date = Date()) -> Date? {
        activeNotificationMuteExpiration(notificationMuteExpirationsBySurfaceId[surfaceId], now: now)
    }

    func activeNotificationMuteExpiration(forTabId tabId: UUID, surfaceId: UUID?, now: Date = Date()) -> Date? {
        let workspaceExpiration = activeWorkspaceNotificationMuteExpiration(forTabId: tabId, now: now)
        let surfaceExpiration = surfaceId.flatMap {
            activeSurfaceNotificationMuteExpiration(forSurfaceId: $0, now: now)
        }
        switch (workspaceExpiration, surfaceExpiration) {
        case (.some(let workspace), .some(let surface)):
            return max(workspace, surface)
        case (.some(let workspace), .none):
            return workspace
        case (.none, .some(let surface)):
            return surface
        case (.none, .none):
            return nil
        }
    }

    func hasActiveWorkspaceNotificationMute(forTabIds tabIds: [UUID], now: Date = Date()) -> Bool {
        tabIds.contains { activeWorkspaceNotificationMuteExpiration(forTabId: $0, now: now) != nil }
    }

    @discardableResult
    func muteNotifications(forTabIds tabIds: [UUID], until expiration: Date) -> Bool {
        let validIds = Set(tabIds)
        guard !validIds.isEmpty else { return false }
        var next = notificationMuteExpirationsByWorkspaceId
        for tabId in validIds {
            next[tabId] = expiration
        }
        guard next != notificationMuteExpirationsByWorkspaceId else { return false }
        notificationMuteExpirationsByWorkspaceId = next
        return true
    }

    @discardableResult
    func unmuteNotifications(forTabIds tabIds: [UUID]) -> Bool {
        let validIds = Set(tabIds)
        guard !validIds.isEmpty else { return false }
        var next = notificationMuteExpirationsByWorkspaceId
        for tabId in validIds {
            next.removeValue(forKey: tabId)
        }
        guard next != notificationMuteExpirationsByWorkspaceId else { return false }
        notificationMuteExpirationsByWorkspaceId = next
        return true
    }

    @discardableResult
    func muteNotifications(forTabId tabId: UUID, surfaceId: UUID, until expiration: Date) -> Bool {
        var next = notificationMuteExpirationsBySurfaceId
        next[surfaceId] = expiration
        guard next != notificationMuteExpirationsBySurfaceId else { return false }
        notificationMuteExpirationsBySurfaceId = next
        return true
    }

    @discardableResult
    func unmuteNotifications(forSurfaceId surfaceId: UUID) -> Bool {
        var next = notificationMuteExpirationsBySurfaceId
        next.removeValue(forKey: surfaceId)
        guard next != notificationMuteExpirationsBySurfaceId else { return false }
        notificationMuteExpirationsBySurfaceId = next
        return true
    }

    private func activeNotificationMuteExpiration(_ expiration: Date?, now: Date) -> Date? {
        guard let expiration, expiration > now else { return nil }
        return expiration
    }
}

#if DEBUG
extension TerminalNotificationStore {
    func clearNotificationMutesForTesting() {
        notificationMuteExpirationsByWorkspaceId = [:]
        notificationMuteExpirationsBySurfaceId = [:]
    }
}
#endif

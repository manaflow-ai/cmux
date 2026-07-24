import Foundation
@testable import CmuxNotifications

/// Recording open router shared by notification-navigation tests.
@MainActor
final class FakeOpenRouting: NotificationOpenRouting {
    var windowSucceeds = true
    var fallbackSucceeds = true
    var routedSucceeds = true
    var titles: [UUID: String] = [:]
    private(set) var log: [String] = []
    private(set) var receivedRowSpaceRevisions: [UInt64?] = []
    private(set) var routedRetargetingValues: [Bool] = []

    func openRouted(
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID?,
        retargetsToLiveSurfaceOwner: Bool,
        notificationId: UUID?,
        scrollRow: Int?,
        scrollTotalRows: Int?,
        scrollRowSpaceRevision: UInt64?
    ) -> Bool {
        receivedRowSpaceRevisions.append(scrollRowSpaceRevision)
        routedRetargetingValues.append(retargetsToLiveSurfaceOwner)
        log.append("routed(tab=\(short(tabId)),surf=\(short(surfaceId))\(panel(panelId)),notif=\(short(notificationId)),row=\(row(scrollRow)),total=\(row(scrollTotalRows)))")
        return routedSucceeds
    }

    func openInWindow(
        windowId: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID?,
        notificationId: UUID?,
        scrollRow: Int?,
        scrollTotalRows: Int?,
        scrollRowSpaceRevision: UInt64?
    ) -> Bool {
        receivedRowSpaceRevisions.append(scrollRowSpaceRevision)
        log.append("window(\(short(windowId)),tab=\(short(tabId)),surf=\(short(surfaceId))\(panel(panelId)),notif=\(short(notificationId)),row=\(row(scrollRow)),total=\(row(scrollTotalRows)))")
        return windowSucceeds
    }

    func openInActiveWindowFallback(
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID?,
        notificationId: UUID?,
        scrollRow: Int?,
        scrollTotalRows: Int?,
        scrollRowSpaceRevision: UInt64?
    ) -> Bool {
        receivedRowSpaceRevisions.append(scrollRowSpaceRevision)
        log.append("fallback(tab=\(short(tabId)),surf=\(short(surfaceId))\(panel(panelId)),notif=\(short(notificationId)),row=\(row(scrollRow)),total=\(row(scrollTotalRows)))")
        return fallbackSucceeds
    }

    func tabTitle(forTabId tabId: UUID) -> String? { titles[tabId] }

    private func short(_ id: UUID?) -> String { id.map { String($0.uuidString.prefix(4)) } ?? "nil" }
    private func panel(_ id: UUID?) -> String { id.map { ",panel=\(short($0))" } ?? "" }
    private func row(_ row: Int?) -> String { row.map(String.init) ?? "nil" }
}

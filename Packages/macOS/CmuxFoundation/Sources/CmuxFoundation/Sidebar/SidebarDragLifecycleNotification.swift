public import Foundation

/// Notification names and userInfo helpers for the sidebar tab-drag lifecycle.
/// Faithful lift of the app-target notification vocabulary; the
/// `Notification.Name` raw values are the in-process wire contract and are kept
/// byte-identical. (A future modernization phase replaces this with an
/// `AsyncStream` on the sidebar model.)
public struct SidebarDragLifecycleNotification {
    /// Posted when the sidebar drag state changes.
    public static let stateDidChange = Notification.Name("cmux.sidebarDragStateDidChange")
    /// Posted to request that any in-flight sidebar drag state be cleared.
    public static let requestClear = Notification.Name("cmux.sidebarDragRequestClear")
    /// userInfo key carrying the dragged tab id.
    public static let tabIdKey = "tabId"
    /// userInfo key carrying the human-readable reason string.
    public static let reasonKey = "reason"

    public init() {}

    /// Posts a state-change notification with the given tab id and reason.
    public func postStateDidChange(tabId: UUID?, reason: String) {
        var userInfo: [AnyHashable: Any] = [Self.reasonKey: reason]
        if let tabId {
            userInfo[Self.tabIdKey] = tabId
        }
        NotificationCenter.default.post(
            name: Self.stateDidChange,
            object: nil,
            userInfo: userInfo
        )
    }

    /// Posts a clear-request notification with the given reason.
    public func postClearRequest(reason: String) {
        NotificationCenter.default.post(
            name: Self.requestClear,
            object: nil,
            userInfo: [Self.reasonKey: reason]
        )
    }

    /// Extracts the tab id from a lifecycle notification, if present.
    public func tabId(from notification: Notification) -> UUID? {
        notification.userInfo?[Self.tabIdKey] as? UUID
    }

    /// Extracts the reason string from a lifecycle notification.
    public func reason(from notification: Notification) -> String {
        notification.userInfo?[Self.reasonKey] as? String ?? "unknown"
    }
}

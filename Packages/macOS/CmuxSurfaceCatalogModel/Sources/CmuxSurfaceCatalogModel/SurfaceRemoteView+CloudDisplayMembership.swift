import Foundation

extension SurfaceRemoteView {
    /// Synthetic tab identity used only to order a display view persisted by
    /// the Cloud frontend projection. It is never sent to a daemon tab API.
    public static let cloudDisplayMembershipViewPrefix = "cloud-display-view:"

    public var isCloudDisplayMembershipView: Bool {
        tabID.hasPrefix(Self.cloudDisplayMembershipViewPrefix)
    }

    /// The durable frontend view token carried by a synthetic display view.
    /// It is intentionally separate from daemon tab ids: a display membership
    /// is persisted outside the daemon layout, but still needs an exact identity
    /// when two clients attach the same display to one workspace.
    public var cloudDisplayMembershipViewID: String? {
        guard isCloudDisplayMembershipView else { return nil }
        let value = String(tabID.dropFirst(Self.cloudDisplayMembershipViewPrefix.count))
        return value.isEmpty ? nil : value
    }
}

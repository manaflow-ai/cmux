import Foundation

extension SurfaceRemoteView {
    /// Synthetic tab identity used only to order a display view persisted by
    /// the Cloud frontend projection. It is never sent to a daemon tab API.
    public static let cloudDisplayMembershipViewPrefix = "cloud-display-view:"

    public var isCloudDisplayMembershipView: Bool {
        tabID.hasPrefix(Self.cloudDisplayMembershipViewPrefix)
    }
}

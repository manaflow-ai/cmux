/// An authorized device for the life of one link session or one forwarded op.
public struct MobileDevicePrincipal: Hashable, Sendable {
    public var install: String
    public var userID: String
    public var platform: String
    public var appVersion: String
    public var displayName: String?

    public init(install: String, userID: String, platform: String, appVersion: String, displayName: String? = nil) {
        self.install = install
        self.userID = userID
        self.platform = platform
        self.appVersion = appVersion
        self.displayName = displayName
    }
}

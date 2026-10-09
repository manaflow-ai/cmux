/// Who sends `hello`.
public struct HelloClient: Hashable, Sendable, Codable {
    public var install: String
    public var platform: String
    public var appVersion: String
    public var build: String?

    public init(install: String, platform: String, appVersion: String, build: String? = nil) {
        self.install = install
        self.platform = platform
        self.appVersion = appVersion
        self.build = build
    }

    enum CodingKeys: String, CodingKey {
        case install, platform, build
        case appVersion = "app_version"
    }
}



public struct PaletteSettingToggle: Identifiable, Sendable, Hashable {
    public let id: String
    public var title: String
    public var isOn: Bool
    public var keywords: [String]

    public init(id: String, title: String, isOn: Bool, keywords: [String] = []) {
        self.id = id
        self.title = title
        self.isOn = isOn
        self.keywords = keywords
    }
}

public protocol PaletteSettingsSource: AnyObject {
    var toggles: [PaletteSettingToggle] { get }
    func setToggle(id: String, isOn: Bool)
}

public protocol PaletteRecentDirectorySource: AnyObject {
    /// Absolute paths, most recent first.
    var recentDirectories: [String] { get }
    func openDirectory(_ path: String)
}

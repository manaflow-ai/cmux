

public struct PaletteOpenInApp: Identifiable, Sendable, Hashable {
    public let id: String
    public var name: String
    public var symbol: String

    public init(id: String, name: String, symbol: String = "app") {
        self.id = id
        self.name = name
        self.symbol = symbol
    }
}

public protocol PaletteOpenInSource: AnyObject {
    var apps: [PaletteOpenInApp] { get }
    /// Directory of the focused terminal, shown as the subtitle.
    var currentDirectory: String? { get }
    func open(appID: String)
}

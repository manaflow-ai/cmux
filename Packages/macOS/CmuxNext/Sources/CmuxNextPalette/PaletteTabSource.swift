

public struct PaletteTab: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case terminal
        case browser
        case other(symbol: String)
    }

    public let id: String
    public var title: String
    public var workspaceTitle: String?
    public var kind: Kind
    public var isSelected: Bool

    public init(id: String, title: String, workspaceTitle: String? = nil, kind: Kind = .terminal, isSelected: Bool = false) {
        self.id = id
        self.title = title
        self.workspaceTitle = workspaceTitle
        self.kind = kind
        self.isSelected = isSelected
    }
}

public protocol PaletteTabSource: AnyObject {
    var tabs: [PaletteTab] { get }
    func selectTab(id: String)
    func renameTab(id: String, to title: String)
    func closeTab(id: String)
}

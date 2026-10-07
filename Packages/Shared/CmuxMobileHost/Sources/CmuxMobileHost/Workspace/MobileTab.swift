/// A tab record of `workspace:<host>` (common.schema.json `Tab`).
public struct MobileTab: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case terminal, browser, agent, other
    }

    public enum Status: String, Hashable, Sendable, Codable {
        case idle, running
        case needsInput = "needs_input"
        case error
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var terminal: String?
    public var url: String?
    public var status: Status?
    public var unread: Int?

    public init(id: String, kind: Kind, title: String, terminal: String? = nil, url: String? = nil,
                status: Status? = nil, unread: Int? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.terminal = terminal
        self.url = url
        self.status = status
        self.unread = unread
    }

    /// The tab without its status fields (what `workspace.tab.upsert` compares).
    var arrangement: MobileTab {
        var copy = self
        copy.status = nil
        copy.unread = nil
        return copy
    }
}

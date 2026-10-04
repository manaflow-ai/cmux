import Foundation

public enum TabKind: Sendable, Hashable, Codable {
    case pty
    /// Browser tab. `TabSnapshot.browserRenderer` says who draws it: the
    /// daemon (CDP frames) or the frontend (WebKit/CEF, never attached).
    case browser
    /// A reference to a terminal on another session
    /// (`remote-terminal-tabs-v1`, `TabSnapshot.remote`). The app attaches
    /// on that session; the home daemon only stores the reference.
    case remoteTerminal
    /// A tab that shows one conversation of a conversation owner
    /// (`conversation-tabs-v1`, `TabSnapshot.conversation`). The app draws it.
    case conversation
    /// A first-party or installed app's page (`app-screens-v1`,
    /// `TabSnapshot.app` and `route`). The app draws it.
    case app
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "pty": self = .pty
        case "browser": self = .browser
        case "remote-terminal": self = .remoteTerminal
        case "conversation": self = .conversation
        case "app": self = .app
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .pty: "pty"
        case .browser: "browser"
        case .remoteTerminal: "remote-terminal"
        case .conversation: "conversation"
        case .app: "app"
        case .other(let value): value
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct CellSize: Sendable, Hashable, Codable {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

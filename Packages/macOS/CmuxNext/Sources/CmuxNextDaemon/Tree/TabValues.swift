import Foundation

public enum TabKind: Sendable, Hashable, Codable {
    case pty
    /// Browser tab. `TabSnapshot.browserRenderer` says who draws it: the
    /// daemon (CDP frames) or the frontend (WebKit/CEF, never attached).
    case browser
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "pty": self = .pty
        case "browser": self = .browser
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .pty: "pty"
        case .browser: "browser"
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

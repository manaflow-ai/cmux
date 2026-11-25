import Foundation
import CmuxNextSettings

/// The composer describes a page of its Add project picker and owns all source actions.
public nonisolated struct AgentProjectPalettePage: Decodable, Equatable, Sendable {
    public nonisolated enum Kind: String, Decodable, Sendable {
        case add, github, machines, folders, url

        /// The only parent this page can be pushed from.
        public var parent: Kind? {
            switch self {
            case .add: nil
            case .folders: .machines
            case .github, .machines, .url: .add
            }
        }
    }

    public nonisolated enum Icon: String, Decodable, Sendable {
        case github, folder, link, plus

        /// An SF Symbol, or `brand:<id>` for a brand's mark as a glyph (GitHub's mark from the shared brand catalog).
        public var symbol: String {
            switch self {
            case .github: "brand:github"
            case .folder: "folder"
            case .link: "link"
            case .plus: "plus"
            }
        }
    }

    public nonisolated struct Scope: Decodable, Equatable, Sendable {
        public let label: String
        public let icon: Icon
    }

    public nonisolated struct Row: Decodable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let icon: Icon?
        public let status: String?
        public let enabled: Bool

        /// The URL page's single row submits the field. All other enabled rows pick an id.
        public func activation(in page: Kind, query: String) -> AgentProjectPaletteEvent? {
            guard enabled else { return nil }
            return page == .url ? .submit(page, query) : .pick(page, id)
        }
    }

    public let page: Kind
    public let title: String
    public let placeholder: String
    public let scope: Scope?
    public let query: String
    public let rows: [Row]
}

/// Messages from the trusted agent pane, scoped to one opening of the project picker.
public nonisolated struct AgentProjectPaletteRequest: Sendable {
    public nonisolated enum Operation: Sendable {
        case show(AgentProjectPalettePage)
        case update(AgentProjectPalettePage, push: Bool)
        case close
    }

    public let id: String
    public let operation: Operation

    static let methods: Set<String> = ["projectPalette.show", "projectPalette.update", "projectPalette.close"]

    init?(method: String, params: JSONValue) {
        guard let id = params["id"]?.stringValue, !id.isEmpty else { return nil }
        self.id = id
        switch method {
        case "projectPalette.close":
            operation = .close
        case "projectPalette.show", "projectPalette.update":
            guard let model = params["model"],
                  let data = try? JSONEncoder().encode(model),
                  let page = try? JSONDecoder().decode(AgentProjectPalettePage.self, from: data),
                  (page.page == .add) == (page.scope == nil),
                  Set(page.rows.map(\.id)).count == page.rows.count else { return nil }
            operation = method == "projectPalette.show"
                ? .show(page)
                : .update(page, push: params["push"]?.boolValue == true)
        default:
            return nil
        }
    }
}

/// Events are returned only to the pane that opened this picker.
public nonisolated enum AgentProjectPaletteEvent: Equatable, Sendable {
    case pick(AgentProjectPalettePage.Kind, String)
    case query(AgentProjectPalettePage.Kind, String)
    case submit(AgentProjectPalettePage.Kind, String)
    case back(AgentProjectPalettePage.Kind, String)
    case closed

    func payload(session: String) -> JSONValue {
        var fields: [String: JSONValue] = ["session": .string(session)]
        switch self {
        case .pick(let page, let id):
            fields["type"] = .string("pick")
            fields["page"] = .string(page.rawValue)
            fields["id"] = .string(id)
        case .query(let page, let text), .submit(let page, let text), .back(let page, let text):
            switch self {
            case .query: fields["type"] = .string("query")
            case .submit: fields["type"] = .string("submit")
            default: fields["type"] = .string("back")
            }
            fields["page"] = .string(page.rawValue)
            fields["text"] = .string(text)
        case .closed:
            fields["type"] = .string("closed")
        }
        return .object(fields)
    }
}

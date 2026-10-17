import Foundation

enum GlobalSearchKind: String, Codable, Sendable {
    case agentSession
    case browser
    case markdown
    case terminal
    case title

    var localizedLabel: String {
        switch self {
        case .agentSession:
            return String(localized: "globalSearch.kind.agentSession", defaultValue: "Agent Session")
        case .browser:
            return String(localized: "globalSearch.kind.browser", defaultValue: "Browser")
        case .markdown:
            return String(localized: "globalSearch.kind.markdown", defaultValue: "Markdown")
        case .terminal:
            return String(localized: "globalSearch.kind.terminal", defaultValue: "Terminal")
        case .title:
            return String(localized: "globalSearch.kind.title", defaultValue: "Title")
        }
    }
}

struct SearchIndexDocument: Sendable, Equatable {
    let id: String
    let windowID: UUID
    let workspaceID: UUID
    let panelID: UUID?
    let kind: GlobalSearchKind
    let title: String
    let location: String
    let anchor: String
    let text: String
    let timestamp: Date

    init(
        id: String,
        windowID: UUID,
        workspaceID: UUID,
        panelID: UUID?,
        kind: GlobalSearchKind,
        title: String,
        location: String,
        anchor: String,
        text: String,
        timestamp: Date = Date.now
    ) {
        self.id = id
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.kind = kind
        self.title = title
        self.location = location
        self.anchor = anchor
        self.text = text
        self.timestamp = timestamp
    }

    static func panelStableID(
        panelID: UUID,
        kind: GlobalSearchKind,
        subtype: String = "document"
    ) -> String {
        [
            panelID.uuidString,
            kind.rawValue,
            subtype
        ].joined(separator: ":")
    }
}

struct SearchIndexHit: Identifiable, Sendable, Equatable {
    let id: String
    let windowID: UUID
    let workspaceID: UUID
    let panelID: UUID?
    let kind: GlobalSearchKind
    let title: String
    let location: String
    let anchor: String
    let snippet: String
    let rank: Double
    let timestamp: Date
}

extension SearchIndexHit {
    func withSnippet(_ snippet: String) -> SearchIndexHit {
        SearchIndexHit(
            id: id,
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID,
            kind: kind,
            title: title,
            location: location,
            anchor: anchor,
            snippet: snippet,
            rank: rank,
            timestamp: timestamp
        )
    }
}

enum SearchIndexError: LocalizedError {
    case openFailed(String)
    case executeFailed(String)
    case prepareFailed(String)
    case bindFailed(String)
    case stepFailed(String)

    var errorDescription: String? {
        switch self {
        case let .openFailed(message):
            return "SQLite open failed: \(message)"
        case let .executeFailed(message):
            return "SQLite execute failed: \(message)"
        case let .prepareFailed(message):
            return "SQLite prepare failed: \(message)"
        case let .bindFailed(message):
            return "SQLite bind failed: \(message)"
        case let .stepFailed(message):
            return "SQLite step failed: \(message)"
        }
    }
}

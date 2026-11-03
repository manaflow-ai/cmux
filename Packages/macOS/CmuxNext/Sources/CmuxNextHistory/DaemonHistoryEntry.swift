public import Foundation

/// One entry of the daemon's merged history (`history.entries.list`; serde snake_case of
/// cmux-history's `HistoryEntry`, times as the catalog's decimal strings). Nonisolated, so
/// `DaemonHistoryClient.decode` builds it off the main actor.
public nonisolated struct DaemonHistoryEntry: Decodable, Sendable, Equatable {
    public var id: String
    public var kind: HistoryEntry.Kind
    public var atMS: Double
    public var title: String
    public var detail: String?
    public var machine: String?
    public var workspace: String?
    public var available: Bool
    public var current: Bool?
    public var running: Bool?
    public var url: String?
    public var profile: String?
    public var closedKind: String?
    public var cwd: String?
    public var command: String?
    public var exitCode: Int?
    public var sessionID: String?
    public var provider: String?
    /// Location rows: the window of the step and the place as recorded (cx-hnmbt.12).
    public var window: String?
    public var location: HistoryTrailLocation?

    enum CodingKeys: String, CodingKey {
        case id, kind, title, detail, machine, workspace, available, current, running, url, profile, cwd, command, provider
        case window, location
        case atMS = "at_ms"
        case closedKind = "closed_kind"
        case exitCode = "exit_code"
        case sessionID = "session_id"
    }

    public var time: Date { Date(timeIntervalSince1970: atMS / 1_000) }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(HistoryEntry.Kind.self, forKey: .kind)
        atMS = try c.decodeCatalogNumber(forKey: .atMS)
        title = try c.decode(String.self, forKey: .title)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        machine = try c.decodeIfPresent(String.self, forKey: .machine)
        workspace = try c.decodeIfPresent(String.self, forKey: .workspace)
        available = try c.decode(Bool.self, forKey: .available)
        current = try c.decodeIfPresent(Bool.self, forKey: .current)
        running = try c.decodeIfPresent(Bool.self, forKey: .running)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        profile = try c.decodeIfPresent(String.self, forKey: .profile)
        closedKind = try c.decodeIfPresent(String.self, forKey: .closedKind)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        exitCode = try c.decodeCatalogNumberIfPresent(forKey: .exitCode).map { Int($0) }
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        window = try c.decodeIfPresent(String.self, forKey: .window)
        location = try c.decodeIfPresent(HistoryTrailLocation.self, forKey: .location)
    }

    public init(id: String, kind: HistoryEntry.Kind, atMS: Double, title: String, available: Bool) {
        self.id = id
        self.kind = kind
        self.atMS = atMS
        self.title = title
        self.available = available
    }

    /// The app's entry for the restore paths (history.open, palette pages). A location comes from the
    /// daemon's trail (`location` and `window`); the caller marks whether its tab is reachable.
    /// `untitled`: the app's localized title of a closed terminal the daemon left untitled.
    public func historyEntry(untitled: String) -> HistoryEntry? {
        let title = kind == .closed && self.title.isEmpty ? untitled : self.title
        let payload: HistoryEntry.Payload
        switch kind {
        case .location:
            guard let location = trailLocation else { return nil }
            payload = .location(location, isCurrent: current == true)
        case .page:
            guard let url else { return nil }
            payload = .page(url: url, profile: profile ?? "default")
        case .closed:
            let itemKind: ClosedItem.Kind = switch closedKind {
            case "browser_tab": .browserTab
            case "conversation_tab": .conversationTab
            case "screen": .screen
            case "workspace": .workspace
            default: .terminalTab
            }
            // The daemon's entry id is `closed:<closed history id>`; the app's closed item id is the rest.
            let itemID = id.hasPrefix("closed:") ? String(id.dropFirst("closed:".count)) : id
            payload = .closed(ClosedItem(id: itemID, kind: itemKind, title: title, machine: machine ?? "local",
                                         workspace: workspace, cwd: cwd, url: url))
        case .agent:
            guard let sessionID, let provider else { return nil }
            payload = .agent(AgentSession(machine: machine ?? "local", provider: provider, sessionID: sessionID, cwd: cwd,
                                          workspace: workspace, startedAt: time, lastActivityAt: time,
                                          endedAt: running == true ? nil : time))
        case .command:
            // Commands come from the daemons' command rows (CommandHistory), not the history module.
            return nil
        }
        return HistoryEntry(id: id, kind: kind, time: time, title: title, detail: detail, machineName: machine,
                            isAvailable: available, payload: payload)
    }
}

public nonisolated struct DaemonHistoryList: Decodable, Sendable {
    public var entries: [DaemonHistoryEntry]
}

/// `history.visit.summaries` row: the omnibox seed of a browser profile.
public nonisolated struct DaemonVisitSummary: Decodable, Sendable, Equatable {
    public var url: String
    public var title: String?
    public var visitCount: Int
    public var lastVisitMS: Double

    enum CodingKeys: String, CodingKey {
        case url, title
        case visitCount = "visit_count"
        case lastVisitMS = "last_visit_ms"
    }

    public init(url: String, title: String?, visitCount: Int, lastVisitMS: Double) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisitMS = lastVisitMS
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        visitCount = Int(try c.decodeCatalogNumber(forKey: .visitCount))
        lastVisitMS = try c.decodeCatalogNumber(forKey: .lastVisitMS)
    }
}

/// The v2 catalog sends 64-bit integers as decimal strings (and smaller ones as numbers): accept both.
nonisolated extension KeyedDecodingContainer {
    func decodeCatalogNumber(forKey key: Key) throws -> Double {
        if let number = try? decode(Double.self, forKey: key) { return number }
        let text = try decode(String.self, forKey: key)
        guard let number = Double(text) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "not a decimal: \(text)")
        }
        return number
    }

    func decodeCatalogNumberIfPresent(forKey key: Key) throws -> Double? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeCatalogNumber(forKey: key)
    }
}

nonisolated extension DaemonHistoryEntry {
    /// A location row's place as the app's location.
    public var trailLocation: HistoryLocation? {
        guard kind == .location, let location else { return nil }
        return location.historyLocation(window: window ?? "")
    }
}

import CmuxNextHistory
import Foundation

/// One entry of the daemon's merged history (`history.entries.list`; serde snake_case of
/// cmux-history's `HistoryEntry`, times as the catalog's decimal strings).
struct DaemonHistoryEntry: Decodable, Sendable, Equatable {
    var id: String
    var kind: HistoryEntry.Kind
    var atMS: Double
    var title: String
    var detail: String?
    var machine: String?
    var workspace: String?
    var available: Bool
    var current: Bool?
    var running: Bool?
    var url: String?
    var profile: String?
    var closedKind: String?
    var cwd: String?
    var command: String?
    var exitCode: Int?
    var sessionID: String?
    var provider: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, title, detail, machine, workspace, available, current, running, url, profile, cwd, command, provider
        case atMS = "at_ms"
        case closedKind = "closed_kind"
        case exitCode = "exit_code"
        case sessionID = "session_id"
    }

    var time: Date { Date(timeIntervalSince1970: atMS / 1_000) }

    init(from decoder: any Decoder) throws {
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
    }

    init(id: String, kind: HistoryEntry.Kind, atMS: Double, title: String, available: Bool) {
        self.id = id
        self.kind = kind
        self.atMS = atMS
        self.title = title
        self.available = available
    }

    /// The app's entry for the restore paths (history.open, palette pages). Locations are nil: the
    /// app owns the trail and reads its own entries.
    func historyEntry() -> HistoryEntry? {
        // The daemon leaves a closed terminal with no name, URL or directory untitled; the app
        // localizes the default.
        let title = kind == .closed && self.title.isEmpty ? Strings.untitledTerminal : self.title
        let payload: HistoryEntry.Payload
        switch kind {
        case .location:
            return nil
        case .page:
            guard let url else { return nil }
            payload = .page(url: url, profile: profile ?? "default")
        case .closed:
            let itemKind: ClosedItem.Kind = switch closedKind {
            case "browser_tab": .browserTab
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
            payload = .command(TerminalCommand(machine: machine ?? "local", terminal: "", command: command, cwd: cwd,
                                               exitCode: exitCode, startedAt: time, duration: nil))
        }
        return HistoryEntry(id: id, kind: kind, time: time, title: title, detail: detail, machineName: machine,
                            isAvailable: available, payload: payload)
    }
}

struct DaemonHistoryList: Decodable, Sendable {
    var entries: [DaemonHistoryEntry]
}

/// `history.visit.summaries` row: the omnibox seed of a browser profile.
struct DaemonVisitSummary: Decodable, Sendable, Equatable {
    var url: String
    var title: String?
    var visitCount: Int
    var lastVisitMS: Double

    enum CodingKeys: String, CodingKey {
        case url, title
        case visitCount = "visit_count"
        case lastVisitMS = "last_visit_ms"
    }

    init(url: String, title: String?, visitCount: Int, lastVisitMS: Double) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisitMS = lastVisitMS
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        visitCount = Int(try c.decodeCatalogNumber(forKey: .visitCount))
        lastVisitMS = try c.decodeCatalogNumber(forKey: .lastVisitMS)
    }
}

/// The v2 catalog sends 64-bit integers as decimal strings (and smaller ones as numbers): accept both.
extension KeyedDecodingContainer {
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

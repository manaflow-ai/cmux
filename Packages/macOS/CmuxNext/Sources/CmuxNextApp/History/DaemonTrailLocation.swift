import CmuxNextDaemon
import CmuxNextHistory
import Foundation

/// A place of the daemon's location trail (`HistoryTrailLocation`, cx-hnmbt.12): the wire form of a
/// ``HistoryLocation`` in `history.trail.record` and in the location rows of `history.entries.list`.
/// The daemon owns the trail; the app reports each step and rebuilds its Back/Forward steps from
/// the rows. An incognito location never goes on the wire.
nonisolated struct DaemonTrailLocation: Codable, Sendable, Equatable {
    var machine: String
    var tab: String
    var title: String
    var page: String?
    var workspace: String?
    var workspaceTitle: String?
    var pane: String?
    var screen: String?
    var room: String?
    var content: String?
    var machineName: String?
    var url: String?
    var cwd: String?

    enum CodingKeys: String, CodingKey {
        case machine, tab, title, page, workspace, pane, screen, room, content, url, cwd
        case workspaceTitle = "workspace_title"
        case machineName = "machine_name"
    }

    init(_ location: HistoryLocation) {
        machine = location.key.machine
        tab = location.key.tab
        title = location.title
        page = location.page
        workspace = location.workspace
        workspaceTitle = location.workspaceTitle
        pane = location.pane
        screen = location.screen
        room = location.room
        content = location.content.rawValue
        machineName = location.machineName
        url = location.url
        cwd = location.cwd
    }

    /// The app's location, shown in `window`.
    func historyLocation(window: String) -> HistoryLocation {
        HistoryLocation(key: .init(machine: machine, tab: tab), window: window, workspace: workspace ?? "",
                        pane: pane ?? "", screen: screen, room: room,
                        content: content.flatMap(HistoryLocation.Content.init(rawValue:)) ?? .other,
                        title: title, workspaceTitle: workspaceTitle, machineName: machineName, url: url, cwd: cwd,
                        page: page)
    }

    /// The JSON object of `history.trail.record`'s `location` field (absent fields left out).
    var wire: JSONValue {
        var object: [String: JSONValue] = ["machine": .string(machine), "tab": .string(tab), "title": .string(title)]
        let optional: [(String, String?)] = [
            ("page", page), ("workspace", workspace), ("workspace_title", workspaceTitle), ("pane", pane),
            ("screen", screen), ("room", room), ("content", content), ("machine_name", machineName), ("url", url),
            ("cwd", cwd),
        ]
        for (key, value) in optional { if let value { object[key] = .string(value) } }
        return .object(object)
    }
}

extension DaemonHistoryClient {
    /// Records one step of the location trail (`history.trail.record`, origin user). `replace`: the
    /// app's trail counted the step as its newest entry again (the same sidebar item, or a quick pass).
    func recordTrail(window: String, location: HistoryLocation, replace: Bool) async throws {
        var params: [String: JSONValue] = [
            "window": .string(window), "location": DaemonTrailLocation(location).wire,
        ]
        if replace { params["replace"] = .bool(true) }
        _ = try await relay.send(operation: "history.trail.record", params: params, idempotencyKey: Self.key())
    }

    /// The daemon's trail, oldest first (at most its 200 entries).
    func trail() async throws -> [(location: HistoryLocation, time: Date)] {
        let rows = try await list(kinds: [.location], text: "", range: .all, limit: 5_000)
        return rows.reversed().compactMap { row in row.trailLocation.map { ($0, row.time) } }
    }
}

extension DaemonHistoryEntry {
    /// A location row's place as the app's location.
    var trailLocation: HistoryLocation? {
        guard kind == .location, let location else { return nil }
        return location.historyLocation(window: window ?? "")
    }
}

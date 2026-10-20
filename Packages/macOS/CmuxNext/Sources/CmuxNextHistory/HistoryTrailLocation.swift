public import Foundation

/// A place of the daemon's location trail (`HistoryTrailLocation` in cmux-tui's
/// resource-operations-v2.json, cx-hnmbt.12): the wire form of a ``HistoryLocation`` in
/// `history.trail.record` and in the location rows of `history.entries.list`. The daemon owns the
/// trail; an app reports each step and rebuilds its Back/Forward steps from the rows. An incognito
/// location never goes on the wire. Absent fields are left out when encoded.
public nonisolated struct HistoryTrailLocation: Codable, Sendable, Equatable {
    public var machine: String
    public var tab: String
    public var title: String
    public var page: String?
    public var workspace: String?
    public var workspaceTitle: String?
    public var pane: String?
    public var screen: String?
    public var room: String?
    public var content: String?
    public var machineName: String?
    public var url: String?
    public var cwd: String?

    enum CodingKeys: String, CodingKey {
        case machine, tab, title, page, workspace, pane, screen, room, content, url, cwd
        case workspaceTitle = "workspace_title"
        case machineName = "machine_name"
    }

    public init(_ location: HistoryLocation) {
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
    public func historyLocation(window: String) -> HistoryLocation {
        HistoryLocation(key: .init(machine: machine, tab: tab), window: window, workspace: workspace ?? "",
                        pane: pane ?? "", screen: screen, room: room,
                        content: content.flatMap(HistoryLocation.Content.init(rawValue:)) ?? .other,
                        title: title, workspaceTitle: workspaceTitle, machineName: machineName, url: url, cwd: cwd,
                        page: page)
    }
}

/// The daemon's whole location trail: its `cmux-next/personal/history.locations` projection (schema 1,
/// cmux-tui `history_ops/trail.rs`), read with `frontend_projection.get` like the hidden-history
/// document. Back/Forward rebuild from it, not from `history.entries.list`: the list leaves out the
/// places History does not show (a terminal titled `~`, a `cmux:` page, `about:blank`), and a step
/// that left the list read as removed (cx-hnmbt.14).
public nonisolated struct HistoryTrailDocument: Decodable, Sendable {
    public static let subject = "history.locations"
    public static let schemaVersion: UInt32 = 1

    nonisolated struct Entry: Decodable, Sendable {
        var window: String
        var atMs: Int64
        var location: HistoryTrailLocation

        enum CodingKeys: String, CodingKey {
            case window, location
            case atMs = "at_ms"
        }
    }

    /// One entry, or nil when it does not decode (that entry is left out, not the document).
    nonisolated struct Lossy: Decodable, Sendable {
        var entry: Entry?

        init(from decoder: any Decoder) throws {
            entry = try? Entry(from: decoder)
        }
    }

    var entries: [Entry]

    enum CodingKeys: String, CodingKey { case entries }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decode([Lossy].self, forKey: .entries).compactMap(\.entry)
    }

    /// Every step, oldest first, with its time on the app's clock.
    public var steps: [(location: HistoryLocation, time: Date)] {
        entries.map { ($0.location.historyLocation(window: $0.window), Date(timeIntervalSince1970: Double($0.atMs) / 1_000)) }
    }
}

/// A trail step as the daemon lists it: its place and time (the app's clock, in ms).
public nonisolated struct HistoryTrailStepID: Hashable, Sendable {
    public var key: HistoryLocation.Key
    public var ms: Int64

    public init(_ key: HistoryLocation.Key, _ time: Date) {
        self.key = key
        ms = Int64((time.timeIntervalSince1970 * 1_000).rounded())
    }
}

/// An app's bookkeeping against the daemon's trail: which daemon steps it last read (a step that
/// leaves them was removed or cleared by another client, so it leaves Back/Forward too) and which
/// steps it recorded while no daemon served the trail (they go to the daemon at the first read).
public nonisolated struct HistoryTrailSync: Sendable {
    public private(set) var known: Set<HistoryTrailStepID> = []
    public var unsent: Set<HistoryTrailStepID> = []

    public init() {}

    /// The daemon's steps (oldest first) with `local`'s steps it lacks kept newest; also the local
    /// entries to send to the daemon now.
    public mutating func adopt(_ steps: [(location: HistoryLocation, time: Date)],
                               local: LocationTrail) -> (trail: LocationTrail, resend: [LocationTrail.Entry]) {
        known = Set(steps.map { HistoryTrailStepID($0.location.key, $0.time) })
        var merged = LocationTrail()
        for step in steps { merged.recordJump(step.location, at: step.time) }
        var resend: [LocationTrail.Entry] = []
        for entry in local.entries where !known.contains(HistoryTrailStepID(entry.location.key, entry.enteredAt)) {
            merged.recordJump(entry.location, at: entry.enteredAt)
            if unsent.contains(HistoryTrailStepID(entry.location.key, entry.enteredAt)), !entry.location.isIncognito {
                resend.append(entry)
            }
        }
        unsent.removeAll()
        return (merged, resend)
    }

    /// Reads the daemon's steps again; answers the steps that left them since the last read.
    public mutating func reconcile(_ steps: [(location: HistoryLocation, time: Date)]) -> Set<HistoryTrailStepID> {
        let now = Set(steps.map { HistoryTrailStepID($0.location.key, $0.time) })
        defer { known = now }
        return known.subtracting(now)
    }
}

public extension HistoryEntry {
    /// A location row greyed while its tab is not reachable (the daemon cannot know; the app can).
    func reachable(_ isAvailable: (HistoryLocation) -> Bool) -> HistoryEntry {
        guard case .location(let location, _) = payload else { return self }
        var entry = self
        entry.isAvailable = isAvailable(location)
        return entry
    }
}

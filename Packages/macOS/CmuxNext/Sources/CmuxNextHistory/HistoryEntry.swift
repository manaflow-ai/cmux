public import Foundation

/// One row of the merged history timeline (plans/cmux-next/history.md 2):
/// what the history page, the palette and `cmux history list` show. Each
/// entry is a read-only view of a fact its owner keeps; `payload` carries
/// what the restore action needs.
public nonisolated struct HistoryEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Hashable, Sendable, Codable {
        case page, location, closed, command, agent
    }

    public enum Payload: Hashable, Sendable {
        /// A page visit in a browser profile.
        case page(url: String, profile: String)
        /// A trail entry; `isCurrent` marks the trail cursor.
        case location(HistoryLocation, isCurrent: Bool)
        /// A closed tab, screen or workspace held by the closed-items log.
        case closed(ClosedItem)
        case command(TerminalCommand)
        case agent(AgentSession)
    }

    /// Qualified: `<kind>:<machine or profile>:<id>`.
    public var id: String
    public var kind: Kind
    public var time: Date
    public var title: String
    /// URL, directory, or workspace, shown under the title.
    public var detail: String?
    /// The machine name for machine facts, nil for local-only entries.
    public var machineName: String?
    /// False while the owning machine is not connected: shown greyed,
    /// restore actions refused.
    public var isAvailable: Bool
    public var payload: Payload

    public init(id: String, kind: Kind, time: Date, title: String, detail: String? = nil,
                machineName: String? = nil, isAvailable: Bool = true, payload: Payload) {
        self.id = id
        self.kind = kind
        self.time = time
        self.title = title
        self.detail = detail
        self.machineName = machineName
        self.isAvailable = isAvailable
        self.payload = payload
    }

    /// Text the search matches against (title, detail, machine, command).
    public var searchText: String {
        var parts = [title]
        if let detail { parts.append(detail) }
        if let machineName { parts.append(machineName) }
        switch payload {
        case .page(let url, _): parts.append(url)
        case .location(let location, _):
            parts += [location.workspaceTitle, location.url, location.cwd].compactMap { $0 }
        case .closed(let item): parts += [item.url, item.cwd].compactMap { $0 }
        case .command(let command): parts += [command.command, command.cwd].compactMap { $0 }
        case .agent(let session): parts += [session.provider, session.sessionID, session.cwd].compactMap { $0 }
        }
        return parts.joined(separator: " ")
    }
}

/// A closed tab, screen or workspace that can be reopened.
public nonisolated struct ClosedItem: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case terminalTab, browserTab, screen, workspace }

    /// The closed-items log's own id for the record.
    public var id: String
    public var kind: Kind
    public var title: String
    public var machine: String
    public var workspace: String?
    public var cwd: String?
    public var url: String?

    public init(id: String, kind: Kind, title: String, machine: String, workspace: String? = nil,
                cwd: String? = nil, url: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.machine = machine
        self.workspace = workspace
        self.cwd = cwd
        self.url = url
    }
}

/// A finished shell command (daemon journal `terminal.command.finished`).
public nonisolated struct TerminalCommand: Hashable, Sendable {
    public var machine: String
    public var terminal: String
    public var command: String?
    public var cwd: String?
    public var exitCode: Int?
    public var startedAt: Date
    public var duration: TimeInterval?

    public init(machine: String, terminal: String, command: String?, cwd: String?, exitCode: Int?,
                startedAt: Date, duration: TimeInterval?) {
        self.machine = machine
        self.terminal = terminal
        self.command = command
        self.cwd = cwd
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.duration = duration
    }
}

public import CmuxNextSettings
import Foundation

/// A live tab that another local cmux build can hand to this App.
///
/// `session.transfer.peers` lists these as JSON (``json``); a destination
/// decodes them with ``init(json:defaultWorkspace:)`` and moves the ones a
/// person or script picks.
public nonisolated struct SessionTransferItem: Sendable, Equatable, Identifiable {
    /// The tab's surface id in its source build.
    public let sourceSurface: String
    /// The source build's workspace that holds the tab.
    public let workspace: String
    /// What the tab is, which decides how it moves.
    public let kind: Kind
    /// The tab's title in the source build (may be empty).
    public let title: String
    /// The tab's working folder, when the source knows it.
    public let cwd: String?
    /// The host portion of an SSH command, when the source exposes one.
    public let sshTarget: String?
    /// A source terminal's original launch command, when available (classic peers).
    public let command: String?
    /// The agent harness (`claude`, `codex`, ...) of an agent or chat tab.
    public let agentHarness: String?
    /// The harness's own session id for an agent, the acpmux session for a chat.
    public let agentSessionID: String?
    /// A `chat` (a cmux-next agent chat, `agentSessionID` its acpmux session): the source build's
    /// acpmux socket, which `acpmux transfer` moves it from.
    public var acpmuxSocket: String?
    /// The source build's acpmux home, paired with ``acpmuxSocket``.
    public var acpmuxHome: String?
    /// What a terminal runs in the foreground, as its build reported it. Moving a terminal
    /// ends it there, so only an ``Activity/idle`` one may be picked; a build that does not
    /// say (classic, a cmux-next build before this field) leaves it ``Activity/unknown``.
    public var activity: Activity = .unknown

    /// `agent` resumes a harness's own session id; `chat` moves an acpmux chat with its history,
    /// queue and draft (a build that predates it skips the record).
    public nonisolated enum Kind: String, Sendable {
        /// A shell: the destination opens a new one in the same folder.
        case terminal
        /// A harness session resumed by its id.
        case agent
        /// A cmux-next agent chat moved through acpmux.
        case chat
    }

    /// A terminal's foreground, on the wire as `idle` (true: its shell only) and
    /// `foreground_program` (the program when `idle` is false); both absent or null: unknown.
    public nonisolated enum Activity: Sendable, Equatable {
        /// Only the terminal's shell runs.
        case idle
        /// A program other than the shell runs (`vim`, `ssh`, a build).
        case running(String)
        /// The build did not say, or could not tell.
        case unknown
    }

    /// The item's id within its build: its source surface.
    public var id: String { sourceSurface }

    /// The wire form `session.transfer.peers` reports and ``init(json:defaultWorkspace:)`` reads.
    public var json: JSONValue {
        [
            "surface": .string(sourceSurface),
            "workspace": .string(workspace),
            "kind": .string(kind.rawValue),
            "title": .string(title),
            "cwd": .optional(cwd),
            "ssh_target": .optional(sshTarget),
            "command": .optional(command),
            "agent": .optional(agentHarness),
            "agent_session": .optional(agentSessionID),
            "acpmux_socket": .optional(acpmuxSocket),
            "acpmux_home": .optional(acpmuxHome),
            "idle": activity.idleFlag.map(JSONValue.bool) ?? .null,
            "foreground_program": .optional(activity.program),
        ]
    }

    /// Creates an item from its parts; the acpmux fields start empty.
    /// - Parameters:
    ///   - sourceSurface: The tab's surface id in its source build.
    ///   - workspace: The source workspace.
    ///   - kind: What the tab is.
    ///   - title: The tab's title.
    ///   - cwd: The tab's folder, if known.
    ///   - sshTarget: The SSH host, if any.
    ///   - command: The launch command, if known.
    ///   - agentHarness: The agent harness, if any.
    ///   - agentSessionID: The agent's session id, if any.
    public init(sourceSurface: String, workspace: String, kind: Kind, title: String, cwd: String?, sshTarget: String?,
                command: String?, agentHarness: String?, agentSessionID: String?) {
        self.sourceSurface = sourceSurface
        self.workspace = workspace
        self.kind = kind
        self.title = title
        self.cwd = cwd
        self.sshTarget = sshTarget
        self.command = command
        self.agentHarness = agentHarness
        self.agentSessionID = agentSessionID
    }

    /// Decodes an item from its wire form, or `nil` without a surface id and a known kind.
    /// - Parameters:
    ///   - json: One entry of a peer's `sessions`.
    ///   - defaultWorkspace: The workspace when the entry names none.
    public init?(json: JSONValue, defaultWorkspace: String = "") {
        guard let object = json.objectValue,
              let sourceSurface = object["surface"]?.stringValue ?? object["id"]?.stringValue,
              let kind = object["kind"]?.stringValue.flatMap(Kind.init(rawValue:)) else { return nil }
        self.sourceSurface = sourceSurface
        workspace = object["workspace"]?.stringValue ?? object["workspace_id"]?.stringValue ?? defaultWorkspace
        self.kind = kind
        title = object["title"]?.stringValue ?? object["name"]?.stringValue ?? ""
        cwd = object["cwd"]?.stringValue
        sshTarget = object["ssh_target"]?.stringValue
        command = object["command"]?.stringValue
        agentHarness = object["agent"]?.stringValue
        agentSessionID = object["agent_session"]?.stringValue
        acpmuxSocket = object["acpmux_socket"]?.stringValue
        acpmuxHome = object["acpmux_home"]?.stringValue
        activity = switch object["idle"]?.boolValue {
        case true?: .idle
        case false?: .running(object["foreground_program"]?.stringValue ?? "")
        case nil: .unknown
        }
    }
}

extension SessionTransferItem.Activity {
    /// `idle` on the wire: nil when unknown.
    nonisolated var idleFlag: Bool? {
        switch self {
        case .idle: true
        case .running: false
        case .unknown: nil
        }
    }

    /// The running program's name, else nil.
    nonisolated var program: String? { if case .running(let program) = self { program } else { nil } }
}

private extension JSONValue {
    nonisolated static func optional(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
}

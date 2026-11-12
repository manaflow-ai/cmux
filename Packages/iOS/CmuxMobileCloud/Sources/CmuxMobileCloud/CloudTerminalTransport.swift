public import Foundation

/// The in-process tunnel a link dials through. Kept alive by every session
/// that used it; dropping the last reference tears the tunnel down.
public protocol CloudTunnel: AnyObject, Sendable {}

/// Starts an in-process WireGuard tunnel from wg-quick text.
public protocol CloudTunnelStarting: Sendable {
    /// Parses `wgQuickConfig` in memory and brings the tunnel up.
    func start(wgQuickConfig: String) async throws -> any CloudTunnel
}

/// One row of the daemon's terminal catalog.
public struct CloudTerminalSummary: Sendable, Equatable, Identifiable, Hashable {
    /// The daemon's terminal id.
    public var id: String
    /// The terminal's name, when it has one.
    public var name: String?
    public var workspaceID: String?
    /// The title the running program set (a shell's `user@host: ~`).
    public var title: String?
    /// The shell's reported working directory.
    public var currentDirectory: String?

    /// Creates a row.
    public init(
        id: String,
        name: String? = nil,
        workspaceID: String? = nil,
        title: String? = nil,
        currentDirectory: String? = nil
    ) {
        self.id = id
        self.name = name
        self.workspaceID = workspaceID
        self.title = title
        self.currentDirectory = currentDirectory
    }

    /// What a list shows for this terminal: ``descriptiveName``, else its id.
    public var displayName: String {
        descriptiveName ?? id
    }

    /// A label that tells this terminal apart without its position: its tab
    /// name, else the title its program set, else its directory relative to
    /// the home directory.
    ///
    /// Nil when none of those says anything, which is the usual case for a
    /// fresh shell: the daemon names no tab, a shell sets no title unless
    /// configured to, and every such shell starts at home. A list numbers
    /// those instead, the way a new terminal is named.
    public var descriptiveName: String? {
        for candidate in [name, title] {
            if let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty {
                return candidate
            }
        }
        guard let directory = currentDirectory.flatMap(Self.homeRelativePath), directory != "~" else {
            return nil
        }
        return directory
    }

    /// `path` with a home directory (`/home/<user>`, `/Users/<user>`,
    /// `/root`) written as `~`; other paths unchanged. Nil for a blank path.
    static func homeRelativePath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let components = trimmed.split(separator: "/")
        let homeDepth: Int
        if components.first == "root" {
            homeDepth = 1
        } else if components.count >= 2, components[0] == "home" || components[0] == "Users" {
            homeDepth = 2
        } else {
            return trimmed
        }
        let rest = components.dropFirst(homeDepth)
        return rest.isEmpty ? "~" : "~/" + rest.joined(separator: "/")
    }
}

/// A workspace owned by a Cloud daemon. Its machine id is carried separately
/// by `CloudMachineConnection`, so this id is stable across clients.
public struct CloudWorkspaceSummary: Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var name: String?
    public var root: String?

    public init(id: String, name: String? = nil, root: String? = nil) {
        self.id = id
        self.name = name
        self.root = root
    }

    public var preferredName: String {
        if let name, !name.isEmpty { return name }
        return root?.split(separator: "/").last.map(String.init) ?? id
    }
}

/// Raw output from an attached terminal, in arrival order.
public enum CloudTerminalOutputEvent: Sendable, Equatable {
    /// Replay bytes for an emulator sized `cols` x `rows`.
    case snapshot(replay: Data, cols: Int, rows: Int)
    /// Live bytes after the snapshot.
    case output(Data)
    /// The daemon resized the terminal.
    case resized(cols: Int, rows: Int)
    /// The terminal's process ended.
    case exited
}

/// An authenticated link to one machine's daemon.
///
/// Methods block on the link, so conformers run them off the main actor.
public protocol CloudTerminalSession: AnyObject, Sendable {
    /// The daemon's remote workspaces.
    func listWorkspaces() async throws -> [CloudWorkspaceSummary]
    /// Creates a workspace with one starter terminal and returns its id.
    func createWorkspace(name: String?) async throws -> String
    /// The daemon's terminals.
    func listTerminals() async throws -> [CloudTerminalSummary]
    /// The daemon's workspaces and terminals together, each terminal filed
    /// under the workspace that shows it. The default reads the two lists,
    /// which cannot place a terminal; a session that can read the whole
    /// session tree does better.
    func loadCatalog() async throws -> (workspaces: [CloudWorkspaceSummary], terminals: [CloudTerminalSummary])
    /// Creates a workspace holding one terminal and returns the terminal id.
    func createTerminal(name: String?) async throws -> String
    /// Creates a terminal in `workspaceID`, beside the ones already there, and
    /// returns its id.
    func createTerminal(inWorkspace workspaceID: String, name: String?) async throws -> String
    /// Streams output for `terminalID` into `handler` until ``detach()``.
    /// The handler runs on library threads.
    func attach(terminalID: String, output: @escaping @Sendable (CloudTerminalOutputEvent) -> Void) async throws
    /// Stops the current attachment.
    func detach()
    /// Queues input bytes for the attached terminal.
    func send(_ bytes: Data)
    /// Reports the phone's grid to the daemon.
    func resize(cols: Int, rows: Int)
    /// Closes the link.
    func disconnect()
}

public extension CloudTerminalSession {
    func loadCatalog() async throws -> (workspaces: [CloudWorkspaceSummary], terminals: [CloudTerminalSummary]) {
        async let workspaces = listWorkspaces()
        async let terminals = listTerminals()
        return try await (workspaces, terminals)
    }

    func listWorkspaces() async throws -> [CloudWorkspaceSummary] { [] }
    func createWorkspace(name: String?) async throws -> String {
        throw CloudAPIError.malformedResponse("remote workspace creation is unavailable")
    }
    func createTerminal(inWorkspace workspaceID: String, name: String?) async throws -> String {
        throw CloudAPIError.malformedResponse("creating a terminal in a workspace is unavailable")
    }
}

/// Opens links with a persistent device identity.
public protocol CloudTerminalConnecting: Sendable {
    /// Connects to `route`, optionally through `tunnel`, and remembers the
    /// daemon under `stateDirectory` so later connects use the enrolled path.
    func connect(
        route: String,
        stateDirectory: URL,
        deviceName: String,
        invitation: String?,
        trustedCarrier: Bool,
        tunnel: (any CloudTunnel)?
    ) async throws -> any CloudTerminalSession
}

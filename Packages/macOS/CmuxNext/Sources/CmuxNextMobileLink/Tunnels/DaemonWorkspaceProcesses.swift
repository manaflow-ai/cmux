public import CmuxMobileHost
public import CmuxNextDaemon

/// The processes of the user's workspace terminals (c14-web.md 3.3), from
/// the daemon: the tree names each workspace's PTY surfaces and
/// `terminal-resources` their process trees (the shell and its
/// descendants; never the terminal host). Asked per request; nothing is
/// sampled in the background.
public struct DaemonWorkspaceProcesses: MobileWorkspaceProcesses {
    private let tree: @Sendable () async throws -> DaemonTree
    private let resources: @Sendable ([SurfaceID]) async throws -> TerminalResourcesRequest.Response

    public init(tree: @escaping @Sendable () async throws -> DaemonTree,
                resources: @escaping @Sendable ([SurfaceID]) async throws -> TerminalResourcesRequest.Response) {
        self.tree = tree
        self.resources = resources
    }

    public init(daemon: DaemonMobileDaemon) {
        let connection = daemon.connection
        self.init(tree: { try await daemon.currentTree() },
                  resources: { try await connection.request(TerminalResourcesRequest(surfaces: $0), timeout: .seconds(5)) })
    }

    public func processes() async -> [MobileWorkspaceProcess] {
        guard let tree = try? await tree() else { return [] }
        var workspaceOf: [SurfaceID: String] = [:]
        for workspace in tree.workspaces {
            guard let id = workspace.resourceID?.rawValue else { continue }
            for tab in workspace.screens.flatMap(\.panes).flatMap(\.tabs) where tab.kind == .pty && !tab.dead {
                workspaceOf[tab.surface] = id
            }
        }
        guard !workspaceOf.isEmpty, let response = try? await resources(Array(workspaceOf.keys)) else { return [] }
        var seen: Set<Int32> = []
        var out: [MobileWorkspaceProcess] = []
        for terminal in response.terminals {
            guard let workspace = workspaceOf[terminal.surface] else { continue }
            for process in terminal.processes where seen.insert(process.pid).inserted {
                out.append(MobileWorkspaceProcess(pid: process.pid, workspace: workspace, name: process.name))
            }
        }
        return out
    }
}

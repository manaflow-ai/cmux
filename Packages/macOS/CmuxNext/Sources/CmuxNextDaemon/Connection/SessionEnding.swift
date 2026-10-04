import Foundation

/// What `endSessionsAndStop` did.
public struct EndedSessions: Sendable, Equatable {
    public var endedTerminals: UInt64
    /// The placed terminals kept their tabs (`end-terminals-keep-layout-v1`).
    public var keptLayout: Bool
    /// Every step that failed, in order. Empty when everything ended.
    public var failures: [EndSessionsFailure]

    public init(endedTerminals: UInt64, keptLayout: Bool, failures: [EndSessionsFailure] = []) {
        self.endedTerminals = endedTerminals
        self.keptLayout = keptLayout
        self.failures = failures
    }
}

/// One step of `endSessionsAndStop` that failed, with the daemon's error.
public struct EndSessionsFailure: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        /// Listing the workspaces to close (End Everything).
        case listWorkspaces
        /// Closing one workspace (End Everything), by its name.
        case closeWorkspace(name: String)
        /// `shutdown-daemon end_terminals`: the terminals did not end.
        case shutdownDaemon
        /// The daemon cannot end sessions (no `terminal-reap-v1`).
        case unsupported
        /// The local acpmux daemon did not end its agents (`_acpmux/shutdown
        /// endAgents`), or did not exit in time.
        case endAgents
    }

    public var step: Step
    public var message: String

    public init(step: Step, message: String) {
        self.step = step
        self.message = message
    }
}

/// Quit's end choices on one daemon (`DaemonConnection.endSessionsAndStop`):
/// stops the connection (so the daemon's exit cannot trigger a reconnect
/// that starts a new daemon), then ends every terminal and stops the daemon
/// (`shutdown-daemon end_terminals`). With `deletingWorkspaces` (End
/// Everything) it first closes every workspace except the store's home
/// workspace, which every close path refuses (`home_not_closable`) and which
/// stays, so the next owner starts with Home only. With `keepingLayout` (End
/// Sessions, Keep Layout) on a daemon that serves
/// `end-terminals-keep-layout-v1`, placed terminals keep their tabs, dead, so
/// the next launch restarts a shell in each with the same splits
/// (`relaunchKeptTabs`); older daemons remove the tabs. Both run on their own
/// socket.
///
/// No step stops the others: a workspace that does not close is recorded
/// and the shutdown still runs. Every failed step is returned in `failures`,
/// so the quit flow can show them and offer Retry; a retry on the same
/// connection runs every step again.
enum SessionEnding {
    static func run(on connection: DaemonConnection, deletingWorkspaces: Bool, keepingLayout: Bool) async -> EndedSessions {
        let identity = await connection.identity
        let keepsLayout = keepingLayout && !deletingWorkspaces && identity?.supports(DaemonCapabilities.shared.endTerminalsKeepLayout) == true
        await connection.close()
        var failures: [EndSessionsFailure] = []
        if deletingWorkspaces { failures = await closeEveryWorkspace(endpoint: await connection.endpoint) }
        do {
            let reply = try await connection.shutdownDaemon(endTerminals: true, keepLayout: keepsLayout)
            return EndedSessions(endedTerminals: reply.endedTerminals ?? 0, keptLayout: keepsLayout, failures: failures)
        } catch {
            failures.append(EndSessionsFailure(step: .shutdownDaemon, message: String(describing: error)))
            return EndedSessions(endedTerminals: 0, keptLayout: false, failures: failures)
        }
    }

    /// Closes every workspace but Home on a short-lived socket (their
    /// terminals detach; `shutdown-daemon end_terminals` then ends them).
    /// Returns one failure per workspace that did not close, or one for the
    /// listing; it never stops at the first.
    static func closeEveryWorkspace(endpoint: DaemonEndpoint?) async -> [EndSessionsFailure] {
        guard let endpoint else { return [EndSessionsFailure(step: .listWorkspaces, message: String(describing: DaemonError.notConnected))] }
        let transport: LineTransport
        do {
            transport = try LineTransport(path: endpoint.socketPath)
        } catch {
            return [EndSessionsFailure(step: .listWorkspaces, message: String(describing: error))]
        }
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
        defer { transport.close() }
        let tree: DaemonTree
        do {
            tree = try await DaemonConnection.perform(ListWorkspacesRequest(), on: transport)
        } catch {
            return [EndSessionsFailure(step: .listWorkspaces, message: String(describing: error))]
        }
        var failures: [EndSessionsFailure] = []
        for workspace in tree.workspaces where !workspace.isHome {
            let ref: WorkspaceRef = workspace.key.map { .key($0) } ?? .handle(workspace.id)
            do {
                _ = try await DaemonConnection.perform(CloseWorkspaceRequest(workspace: ref, mutation: nil), on: transport)
            } catch {
                failures.append(EndSessionsFailure(step: .closeWorkspace(name: workspace.name), message: String(describing: error)))
            }
        }
        return failures
    }
}

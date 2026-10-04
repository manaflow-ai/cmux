import CmuxNextDaemon
import CmuxNextSettings
import Foundation

/// `debug.surfaces` (DEBUG builds): each terminal pane's daemon `terminal_id`
/// and the pid of its `__terminal-host` (`host_pid`, from
/// `terminal-resources`; null for a PTY inside the daemon or when the
/// daemon cannot say), so a live proof can kill the exact host behind a tab
/// and check its "Terminal lost" banner.
enum SurfaceHostReport {
    /// One terminal pane's identity.
    nonisolated struct Identity: Equatable, Sendable {
        var terminalID: String?
        var hostPID: Int32?
    }

    /// The pane's daemon tab, for the host query.
    nonisolated struct Target: Sendable {
        var paneKey: String
        var surface: SurfaceID
        var terminalID: String?
        var connection: DaemonConnection?
        var supported: Bool
    }

    /// Adds `terminal_id` and `host_pid` to every pane object of `report`
    /// whose `pane` key is in `identities`; other panes are unchanged.
    nonisolated static func annotate(_ report: CmuxNextSettings.JSONValue, identities: [String: Identity]) -> CmuxNextSettings.JSONValue {
        report
    }

    /// Terminal panes of every window, with their daemon tab.
    @MainActor static func targets(_ services: AppServices) -> [Target] {
        SurfaceDiagnosticsReport.statuses(services).compactMap { row in
            guard let key = row.pane.currentTabKey, let (tab, pane) = services.locateTab(key), tab.kind == .pty else { return nil }
            let daemon = services.daemon(for: pane)
            return Target(paneKey: row.status.paneKey, surface: tab.surface, terminalID: tab.terminalID?.rawValue,
                          connection: daemon.connection, supported: daemon.supports(TerminalResourcesRequest.capability))
        }
    }

    /// Asks each target's daemon for its host pid (one request per daemon).
    nonisolated static func identities(_ targets: [Target]) async -> [String: Identity] {
        var result: [String: Identity] = [:]
        var groups: [ObjectIdentifier: (DaemonConnection, [Target])] = [:]
        for target in targets {
            result[target.paneKey] = Identity(terminalID: target.terminalID, hostPID: nil)
            guard target.supported, let connection = target.connection else { continue }
            groups[ObjectIdentifier(connection), default: (connection, [])].1.append(target)
        }
        for (connection, members) in groups.values {
            let request = TerminalResourcesRequest(surfaces: members.map(\.surface))
            guard let response = try? await connection.request(request, timeout: .seconds(1)) else { continue }
            let hosts = Dictionary(response.terminals.map { ($0.surface, $0.host?.pid) }, uniquingKeysWith: { first, _ in first })
            for member in members { result[member.paneKey]?.hostPID = hosts[member.surface] ?? nil }
        }
        return result
    }
}

import CmuxNextDaemon
import Foundation

/// Reads `QuitFacts` for an interactive quit: the local daemon's PTY tabs
/// (from the mirrored tree), each one's foreground program (`process-info`)
/// and CPU time (`terminal-resources`), asked concurrently with a short
/// deadline. A terminal that does not answer counts as idle, so a slow
/// daemon never holds up the sheet by more than the deadline.
@MainActor
enum QuitFactsReader {
    nonisolated static let deadline: Duration = .seconds(1)

    static func read(_ services: AppServices) async -> QuitFacts {
        let local = services.machines.local
        let windows = services.windows!
        var kept: [SurfaceID] = []
        var incognito: [SurfaceID] = []
        var seen = Set<String>()
        for workspace in local.store.workspaces {
            let isIncognito = windows.isIncognito(workspace: workspace.id)
            for tab in workspace.screens.flatMap(\.panes).flatMap(\.tabs) where tab.kind == .pty && !tab.dead {
                let identity = tab.terminalID.map { "t:\($0.rawValue)" } ?? "s:\(tab.surface.rawValue)"
                guard seen.insert(identity).inserted else { continue }
                if isIncognito { incognito.append(tab.surface) } else { kept.append(tab.surface) }
            }
        }
        let remote = !services.machines.remoteDaemons.isEmpty
        guard let connection = local.connection, !(kept.isEmpty && incognito.isEmpty) else {
            return QuitFacts(terminals: kept.count, programs: [], incognitoPrograms: [], remoteSessions: remote)
        }
        let readsCPU = local.supports(TerminalResourcesRequest.capability)
        async let programs = foregroundPrograms(kept + incognito, on: connection)
        async let cpu = readsCPU ? cpuTimes(kept, on: connection) : [:]
        let (names, times) = await (programs, cpu)
        return QuitFacts(
            terminals: kept.count,
            programs: kept.compactMap { surface in
                names[surface].map { QuitProgram(name: $0, cpuNanos: times[surface] ?? 0) }
            },
            incognitoPrograms: Array(Set(incognito.compactMap { names[$0] })).sorted(),
            remoteSessions: remote
        )
    }

    /// Each surface's foreground program other than its shell.
    private nonisolated static func foregroundPrograms(_ surfaces: [SurfaceID], on connection: DaemonConnection) async -> [SurfaceID: String] {
        await withTaskGroup(of: (SurfaceID, String?).self) { group in
            for surface in surfaces {
                group.addTask {
                    (surface, try? await connection.request(TerminalProcessInfoRequest(surface: surface), timeout: deadline).runningProgram)
                }
            }
            var names: [SurfaceID: String] = [:]
            for await (surface, name) in group { if let name { names[surface] = name } }
            return names
        }
    }

    /// CPU time of each terminal's processes other than its shell (the
    /// first process in `terminal-resources`), one request for all.
    private nonisolated static func cpuTimes(_ surfaces: [SurfaceID], on connection: DaemonConnection) async -> [SurfaceID: UInt64] {
        guard !surfaces.isEmpty,
              let response = try? await connection.request(TerminalResourcesRequest(surfaces: surfaces), timeout: deadline) else { return [:] }
        var times: [SurfaceID: UInt64] = [:]
        for terminal in response.terminals {
            times[terminal.surface] = terminal.processes.dropFirst().reduce(0) { $0 + $1.cpuNanos }
        }
        return times
    }
}

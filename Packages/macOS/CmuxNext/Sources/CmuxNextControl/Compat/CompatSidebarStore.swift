import Foundation
import Synchronization

/// Sidebar metadata agents and hooks report through the old v1 verbs
/// (`set_status`, `set_progress`, `log`, `set_agent_pid`), per workspace.
///
/// In memory for the app process only; bounded (64 status keys and 200 log
/// lines per workspace, oldest dropped). The sidebar does not render it yet
/// (cli-compat.md follow-up); `list_status`, `list_log`, and `sidebar_state`
/// read it back, so hooks and scripts see what they wrote.
final class CompatSidebarStore: Sendable {
    struct Status: Sendable, Hashable {
        var value: String
        var icon: String?
        var color: String?
        var url: String?
        var priority: Int?
        var format: String?
    }

    struct LogLine: Sendable, Hashable {
        var level: String
        var source: String?
        var message: String
    }

    struct Workspace: Sendable {
        var statuses: [(key: String, status: Status)] = []
        var progress: (value: Double, label: String?)?
        var log: [LogLine] = []
        var agentPIDs: [String: Int] = [:]
    }

    static let statusLimit = 64
    static let logLimit = 200

    private let state = Mutex([String: Workspace]())

    func workspace(_ uuid: String) -> Workspace { state.withLock { $0[uuid] ?? Workspace() } }

    func setStatus(_ key: String, _ status: Status, workspace uuid: String) {
        state.withLock { all in
            var entry = all[uuid] ?? Workspace()
            if let index = entry.statuses.firstIndex(where: { $0.key == key }) {
                entry.statuses[index].status = status
            } else {
                entry.statuses.append((key, status))
                if entry.statuses.count > Self.statusLimit { entry.statuses.removeFirst() }
            }
            all[uuid] = entry
        }
    }

    func clearStatus(_ key: String?, workspace uuid: String) {
        state.withLock { all in
            guard var entry = all[uuid] else { return }
            if let key { entry.statuses.removeAll { $0.key == key } } else { entry.statuses.removeAll() }
            all[uuid] = entry
        }
    }

    func setProgress(_ progress: (value: Double, label: String?)?, workspace uuid: String) {
        state.withLock { all in
            var entry = all[uuid] ?? Workspace()
            entry.progress = progress
            all[uuid] = entry
        }
    }

    func appendLog(_ line: LogLine, workspace uuid: String) {
        state.withLock { all in
            var entry = all[uuid] ?? Workspace()
            entry.log.append(line)
            if entry.log.count > Self.logLimit { entry.log.removeFirst(entry.log.count - Self.logLimit) }
            all[uuid] = entry
        }
    }

    func clearLog(workspace uuid: String) {
        state.withLock { $0[uuid]?.log.removeAll() }
    }

    func setAgentPID(_ key: String, _ pid: Int?, workspace uuid: String) {
        state.withLock { all in
            var entry = all[uuid] ?? Workspace()
            entry.agentPIDs[key] = pid
            all[uuid] = entry
        }
    }
}

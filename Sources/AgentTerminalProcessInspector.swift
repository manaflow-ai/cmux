import CmuxTerminalCore
import Darwin
import Foundation

/// Reads bounded foreground-process identity, argv, and host-visible environment off the main actor.
struct AgentTerminalProcessInspector: Sendable {
    @concurrent
    func snapshot(pid: Int32, runtimeGeneration: UInt64) async -> AgentTerminalProcessSnapshot? {
        guard let identity = processIdentity(pid: pid, runtimeGeneration: runtimeGeneration) else { return nil }
        let command = CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: Int(pid))
        return AgentTerminalProcessSnapshot(
            identity: identity,
            executablePath: executablePath(pid: pid),
            arguments: command?.arguments ?? [],
            environment: command?.environment ?? [:]
        )
    }

    @concurrent
    func identity(pid: Int32, runtimeGeneration: UInt64) async -> AgentTerminalProcessIdentity? {
        processIdentity(pid: pid, runtimeGeneration: runtimeGeneration)
    }

    private func processIdentity(pid: Int32, runtimeGeneration: UInt64) -> AgentTerminalProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        guard size == expectedSize else { return nil }
        return AgentTerminalProcessIdentity(
            pid: pid,
            startSeconds: Int64(info.pbi_start_tvsec),
            startMicroseconds: Int64(info.pbi_start_tvusec),
            runtimeGeneration: runtimeGeneration
        )
    }

    private func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        return String(cString: buffer)
    }

}

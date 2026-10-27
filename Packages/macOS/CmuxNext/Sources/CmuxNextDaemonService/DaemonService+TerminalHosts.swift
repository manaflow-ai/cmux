public import CmuxNextDaemon

extension DaemonService {
    /// The pids of this local daemon's terminal hosts, from its own terminal list (`terminal-resources`, a plain read
    /// that takes no trace control slot). Empty for a remote daemon or one without the command; nil when it did not
    /// answer within `timeout`. The resource samples read them (p09-observability-121).
    public func terminalHostPIDs(timeout: Duration = .seconds(1)) async -> [Int32]? {
        guard isLocal, supports(TerminalResourcesRequest.capability) else { return [] }
        guard let connection,
              let reply = try? await connection.request(TerminalResourcesRequest(surfaces: nil), timeout: timeout) else { return nil }
        return reply.terminals.compactMap { $0.host?.pid }
    }
}

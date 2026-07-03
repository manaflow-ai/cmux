extension RemoteTmuxController {
    /// Runs a mirror attach operation under the per-host in-flight guard.
    func withMirrorAttachGuard<T>(
        host: RemoteTmuxHost,
        operation: () async throws -> T
    ) async throws -> T {
        guard windowRegistry.beginAttach(hostHash: host.connectionHash) else {
            throw RemoteTmuxError.unreachable("already attaching \(host.destination)")
        }
        defer { windowRegistry.endAttach(hostHash: host.connectionHash) }
        return try await operation()
    }

    /// Runs the common non-UI preflight for both current-window and dedicated-window attach.
    func prepareMirrorAttach(
        host: RemoteTmuxHost,
        createIfEmpty: Bool,
        afterDiscovery: ([RemoteTmuxSession]) throws -> RemoteTmuxAttachOutcome?
    ) async throws -> RemoteTmuxMirrorAttachPreflight {
        let sessions: [RemoteTmuxSession]
        do {
            sessions = try await transport(for: host).discoverMirrorSessions(createIfEmpty: createIfEmpty)
        } catch let error as RemoteTmuxError {
            if case .commandFailed(_, let stderr) = error,
               RemoteTmuxSSHTransport.indicatesInteractiveRetryWillHelp(stderr) {
                return .authRequired(sshArgv: host.interactiveAuthInvocation())
            }
            throw error
        }
        guard !sessions.isEmpty else {
            throw RemoteTmuxError.unreachable("no tmux sessions on \(host.destination)")
        }
        if let outcome = try afterDiscovery(sessions) {
            switch outcome {
            case .authRequired(let sshArgv):
                return .authRequired(sshArgv: sshArgv)
            case .mirrored(let windowId):
                return .mirrored(windowId: windowId)
            }
        }

        try Task.checkCancellation()
        try await ensureControlMasterReadyForBurst(host: host)
        return .sessions(sessions)
    }
}

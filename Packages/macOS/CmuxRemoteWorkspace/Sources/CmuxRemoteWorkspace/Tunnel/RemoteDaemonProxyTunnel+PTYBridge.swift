public import Dispatch
internal import Foundation

extension RemoteDaemonProxyTunnel {
    /// Starts a single-use loopback bridge for one stable logical attach generation.
    public func startPTYBridge(
        sessionID: String,
        lifecycleID: String,
        attachmentID: String,
        command: String?,
        requireExisting: Bool,
        onLifecycleEnded: @escaping @Sendable () -> Void = {}
    ) throws -> RemotePTYBridgeServer.Endpoint {
        try queue.sync {
            guard let rpcClient, !isStopped else {
                throw NSError(domain: "cmux.remote.pty", code: 33, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon tunnel is not ready",
                ])
            }
            let lifecycleKey = RemotePTYLifecycleKey(sessionID: sessionID, lifecycleID: lifecycleID)
            let bridgeID = UUID()
            try ptyLifecycleRegistry.registerBridge(
                key: lifecycleKey,
                attachmentID: attachmentID,
                bridgeID: bridgeID
            )
            let server = RemotePTYBridgeServer(
                rpcClient: rpcClient,
                sessionID: lifecycleKey.sessionID,
                lifecycleID: lifecycleKey.lifecycleID,
                attachmentID: attachmentID,
                command: command,
                requireExisting: requireExisting,
                strings: ptyBridgeStrings,
                clock: clock
            ) { [weak self] disposition in
                guard let self else { return }
                self.queue.async {
                    guard let record = self.ptyBridgeServers.removeValue(forKey: bridgeID) else { return }
                    let lifecycleEnded = self.ptyLifecycleRegistry.bridgeStopped(
                        key: record.lifecycleKey,
                        bridgeID: bridgeID,
                        disposition: disposition
                    )
                    if lifecycleEnded { onLifecycleEnded() }
                }
            }
            do {
                let endpoint = try server.start()
                ptyBridgeServers[bridgeID] = RemotePTYBridgeServerRecord(
                    server: server,
                    lifecycleKey: lifecycleKey,
                    onLifecycleEnded: onLifecycleEnded
                )
                return endpoint
            } catch {
                let lifecycleEnded = ptyLifecycleRegistry.bridgeStopped(
                    key: lifecycleKey,
                    bridgeID: bridgeID,
                    disposition: .unused
                )
                if lifecycleEnded { onLifecycleEnded() }
                throw error
            }
        }
    }

    /// Intentionally closes a remote PTY and gates every known logical attach generation first.
    ///
    /// - Parameters:
    ///   - sessionID: Persistent PTY session to terminate.
    ///   - deadline: Monotonic deadline shared with the originating cleanup call.
    public func closePTY(
        sessionID: String,
        deadline: DispatchTime = .distantFuture
    ) throws {
        let preparation = try queue.sync {
            guard rpcClient != nil, !isStopped else {
                throw NSError(domain: "cmux.remote.pty", code: 31, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon tunnel is not ready",
                ])
            }
            let previous = ptyLifecycleRegistry.requestIntentionalClose(sessionID: sessionID)
            let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchingServers = ptyBridgeServers.values.filter {
                $0.lifecycleKey.sessionID == normalizedSessionID
            }
            return (previous: previous, matchingServers: matchingServers)
        }

        // The public close operation is synchronous. Join in-flight attach
        // RPCs on this caller thread, never on the tunnel/bridge/RPC queues
        // that must deliver their completion signals.
        for record in preparation.matchingServers {
            guard record.server.stopAndWaitForAttachCompletion(deadline: deadline) else {
                queue.sync {
                    ptyLifecycleRegistry.rollbackIntentionalClose(preparation.previous)
                }
                throw Self.ptyOperationTimedOutError()
            }
        }
        try queue.sync {
            guard let rpcClient, !isStopped else {
                ptyLifecycleRegistry.completeIntentionalClose(preparation.previous)
                throw NSError(domain: "cmux.remote.pty", code: 31, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon tunnel is not ready",
                ])
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard deadline.uptimeNanoseconds > now else {
                ptyLifecycleRegistry.rollbackIntentionalClose(preparation.previous)
                throw Self.ptyOperationTimedOutError()
            }
            let remainingTimeout = min(
                8.0,
                Double(deadline.uptimeNanoseconds - now) / 1_000_000_000
            )
            do {
                try rpcClient.closePTY(sessionID: sessionID, timeout: remainingTimeout)
                ptyLifecycleRegistry.completeIntentionalClose(preparation.previous)
            } catch {
                if Self.ptyCloseWasDefinitivelyRejected(error) {
                    ptyLifecycleRegistry.rollbackIntentionalClose(preparation.previous)
                } else {
                    ptyLifecycleRegistry.completeIntentionalClose(preparation.previous)
                }
                throw error
            }
        }
    }

    private static func ptyOperationTimedOutError() -> NSError {
        NSError(domain: "cmux.remote.pty", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "timed out waiting for remote PTY operation",
        ])
    }

    private static func ptyCloseWasDefinitivelyRejected(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "cmux.remote.daemon.rpc" &&
            nsError.code == 14 &&
            nsError.localizedDescription.range(
                of: "pty.close failed (invalid_params)",
                options: [.caseInsensitive]
            ) != nil
    }

    /// Returns the shared tunnel decision for one logical attach generation.
    public func ptySessionLifecycle(
        sessionID: String,
        lifecycleID: String
    ) -> RemotePTYSessionLifecycle {
        queue.sync {
            ptyLifecycleRegistry.lifecycle(
                for: RemotePTYLifecycleKey(sessionID: sessionID, lifecycleID: lifecycleID)
            )
        }
    }

    /// Retires one logical attach generation after its CLI reconciles terminal end state.
    public func acknowledgePTYLifecycle(sessionID: String, lifecycleID: String) {
        queue.sync {
            ptyLifecycleRegistry.acknowledge(
                RemotePTYLifecycleKey(sessionID: sessionID, lifecycleID: lifecycleID)
            )
        }
    }

    /// Retires a logical attach generation only when this tunnel still owns it.
    ///
    /// - Parameters:
    ///   - sessionID: Persistent PTY session containing the generation.
    ///   - lifecycleID: Stable logical generation identifier.
    /// - Returns: `true` when the generation was known and retired.
    public func acknowledgePTYLifecycleIfKnown(sessionID: String, lifecycleID: String) -> Bool {
        queue.sync {
            ptyLifecycleRegistry.acknowledgeIfKnown(
                RemotePTYLifecycleKey(sessionID: sessionID, lifecycleID: lifecycleID)
            )
        }
    }
}

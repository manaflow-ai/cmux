internal import Foundation

private enum InheritedReverseRelayCancellationOutcome: Sendable {
    case cancelled
    case ignored(String)
}

extension RemoteSessionCoordinator {
    /// Removes a reverse forward left on a ControlPersist master by a
    /// pre-dedicated-relay app instance, then continues startup on `queue`.
    ///
    /// Do not require an explicit `ControlPath`: `ssh -O` can resolve one from
    /// the user's host config, and exits without creating a connection when no
    /// master is available.
    func beginInheritedReverseRelayCancellationLocked(
        remotePath: String,
        relayPort: Int,
        relayID: String,
        relayToken: String,
        localSocketPath: String
    ) {
        let forwardSpec = "127.0.0.1:\(relayPort)"
        let arguments = sshCommonArguments(batchMode: true) + [
            "-O", "cancel",
            "-R", forwardSpec,
            configuration.destination,
        ]
        let request = RemoteProcessRequest(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            environment: configuration.sshProcessEnvironment,
            timeout: 4
        )
        let token = UUID()
        let cancellation = RemoteProcessCancellationOperation()
        let processRunner = self.processRunner

        let task = Task { [weak self] in
            let outcome = await withTaskCancellationHandler {
                await Self.runInheritedReverseRelayCancellation(
                    request: request,
                    processRunner: processRunner,
                    cancellation: cancellation
                )
            } onCancel: {
                cancellation.cancel()
            }
            guard !Task.isCancelled else { return }
            self?.queue.async { [weak self] in
                self?.finishInheritedReverseRelayCancellationLocked(
                    token: token,
                    outcome: outcome,
                    remotePath: remotePath,
                    relayPort: relayPort,
                    relayID: relayID,
                    relayToken: relayToken,
                    localSocketPath: localSocketPath
                )
            }
        }
        reverseRelayStartupPhase = .cancellingInheritedForward(
            token: token,
            task: task,
            cancellation: cancellation
        )
    }

    private static func runInheritedReverseRelayCancellation(
        request: RemoteProcessRequest,
        processRunner: any RemoteSessionProcessRunning,
        cancellation: RemoteProcessCancellationOperation
    ) async -> InheritedReverseRelayCancellationOutcome {
        await withCheckedContinuation { continuation in
            // The process runner is intentionally blocking. Keep that legacy
            // boundary on a utility thread while the owning Task suspends.
            DispatchQueue.global(qos: .utility).async {
                let outcome: InheritedReverseRelayCancellationOutcome
                do {
                    let result = try processRunner.run(request, operation: cancellation)
                    if result.status == 0 {
                        outcome = .cancelled
                    } else {
                        let detail = bestErrorLine(stderr: result.stderr, stdout: result.stdout)
                            ?? "ssh exited \(result.status)"
                        outcome = .ignored(detail)
                    }
                } catch {
                    outcome = .ignored(error.localizedDescription)
                }
                continuation.resume(returning: outcome)
            }
        }
    }

    private func finishInheritedReverseRelayCancellationLocked(
        token: UUID,
        outcome: InheritedReverseRelayCancellationOutcome,
        remotePath: String,
        relayPort: Int,
        relayID: String,
        relayToken: String,
        localSocketPath: String
    ) {
        guard reverseRelayStartupPhase.token == token else { return }
        reverseRelayStartupPhase = .idle

        switch outcome {
        case .cancelled:
            debugLog(
                "remote.relay.inheritedForward.cancelled " +
                "relayPort=\(relayPort) \(debugConfigSummary())"
            )
        case .ignored(let detail):
            debugLog(
                "remote.relay.inheritedForward.cancelIgnored " +
                "relayPort=\(relayPort) \(detail) \(debugConfigSummary())"
            )
        }

        guard !isStopping, daemonReady, reverseRelayProcess == nil else { return }
        launchReverseRelayLocked(
            remotePath: remotePath,
            relayPort: relayPort,
            relayID: relayID,
            relayToken: relayToken,
            localSocketPath: localSocketPath
        )
    }

    func cancelReverseRelayStartupLocked() {
        guard case .cancellingInheritedForward(
            _,
            let task,
            let cancellation
        ) = reverseRelayStartupPhase else {
            return
        }
        reverseRelayStartupPhase = .idle
        task.cancel()
        cancellation.cancel()
    }
}

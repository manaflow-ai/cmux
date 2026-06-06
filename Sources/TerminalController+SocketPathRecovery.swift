import CmuxSocketControl
import Darwin
import Foundation

extension TerminalController {
    nonisolated func startSocketFileHealthWatcher() {
        let snapshot = listenerStateSnapshot()
        guard snapshot.isRunning,
              snapshot.serverSocket >= 0 else {
            return
        }

        let directoryPath = SocketPathProbe.parentDirectory(path: snapshot.socketPath)
        let fd = open(directoryPath, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else {
            reportSocketListenerFailure(
                message: "socket.listener.path.watch.failed",
                stage: "socket_file_watch_start",
                errnoCode: errno,
                extra: [
                    "directoryPath": directoryPath,
                    "generation": snapshot.activeGeneration
                ]
            )
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .rename, .delete],
            queue: socketListenerQueue
        )
        source.setEventHandler { [weak self] in
            self?.performSocketFileHealthCheck()
        }
        source.setCancelHandler {
            close(fd)
        }

        let installResult = installSocketFileHealthWatchSource(source, snapshot: snapshot)
        if installResult.shouldStart {
            source.resume()
            installResult.previousSource?.cancel()
            socketListenerQueue.async { [weak self] in
                self?.performSocketFileHealthCheck()
            }
        } else {
            source.resume()
            source.cancel()
        }
    }

    @discardableResult
    nonisolated func startSocketFileRecoveryRetryWatcher(
        socketPath retrySocketPath: String,
        accessMode retryAccessMode: SocketControlMode
    ) -> Bool {
        let directoryPath = SocketPathProbe.parentDirectory(path: retrySocketPath)
        let fd = open(directoryPath, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else {
            reportSocketListenerFailure(
                message: "socket.listener.path.recovery.retry_watch_failed",
                stage: "socket_file_recovery_retry_watch_start",
                errnoCode: errno,
                extra: [
                    "directoryPath": directoryPath,
                    "path": retrySocketPath
                ]
            )
            return false
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .rename, .delete],
            queue: socketListenerQueue
        )
        source.setEventHandler { [weak self, weak source, retrySocketPath, retryAccessMode] in
            guard let source else { return }
            self?.retrySocketListenerStartFromRecoveryWatcher(
                watchSource: source,
                socketPath: retrySocketPath,
                accessMode: retryAccessMode
            )
        }
        source.setCancelHandler {
            close(fd)
        }

        let installResult = installSocketFileRecoveryRetryWatchSource(
            source,
            socketPath: retrySocketPath,
            accessMode: retryAccessMode
        )
        if installResult.shouldStart {
            source.resume()
            installResult.previousSource?.cancel()
            return true
        } else {
            source.resume()
            source.cancel()
            return false
        }
    }

    private nonisolated func retrySocketListenerStartFromRecoveryWatcher(
        watchSource: DispatchSourceFileSystemObject,
        socketPath retrySocketPath: String,
        accessMode retryAccessMode: SocketControlMode
    ) {
        guard let retryToken = beginSocketFileRecoveryRetry(from: watchSource) else {
            return
        }

        Task { @MainActor [weak self, retrySocketPath, retryAccessMode, retryToken] in
            guard let self else { return }
            guard self.socketFileRecoveryRetryIsCurrent(retryToken) else { return }
            guard let tabManager = self.tabManager else {
                self.clearSocketListenerStartInProgress()
                return
            }

            let didStart = self.start(
                tabManager: tabManager,
                socketPath: retrySocketPath,
                accessMode: retryAccessMode,
                preserveAcceptFailureStreak: true
            )
            if !didStart {
                let failedPath = self.listenerStateSnapshot().socketPath
                self.reportSocketListenerFailure(
                    message: "socket.listener.path.recovery.retry_failed",
                    stage: "socket_file_recovery_retry",
                    extra: [
                        "path": failedPath,
                        "requestedPath": retrySocketPath,
                        "mode": retryAccessMode.rawValue
                    ]
                )
                self.clearSocketListenerStartInProgress()
                self.startSocketFileRecoveryRetryWatcher(
                    socketPath: retrySocketPath,
                    accessMode: retryAccessMode
                )
            }
        }
    }

    nonisolated func performSocketFileHealthCheck() {
        let snapshot = listenerStateSnapshot()
        guard snapshot.isRunning,
              snapshot.serverSocket >= 0,
              !snapshot.listenerStartInProgress else {
            return
        }

        let pathStatus = SocketPathProbe.observedStatus(
            path: snapshot.socketPath,
            expectedIdentity: snapshot.boundSocketPathIdentity
        )
        let recoveryPath: String
        let shouldUnlinkNonSocketReplacement: Bool
        let nonSocketReplacementIdentity: SocketPathIdentity?

        guard pathStatus.shouldAttemptListenerRecovery else {
            return
        }
        recoveryPath = snapshot.socketPath
        if case .notSocket = pathStatus {
            shouldUnlinkNonSocketReplacement = true
            nonSocketReplacementIdentity = SocketPathProbe.fileIdentity(path: snapshot.socketPath)
        } else {
            shouldUnlinkNonSocketReplacement = false
            nonSocketReplacementIdentity = nil
        }

        let shouldScheduleRecovery = scheduleSocketFileRecoveryIfCurrent(snapshot)
        guard shouldScheduleRecovery else {
            return
        }

        let recoveryData: [String: Any] = [
            "pathStatus": pathStatus.debugLabel,
            "generation": snapshot.activeGeneration,
            "recoveryPath": recoveryPath
        ]
        reportSocketListenerFailure(
            message: "socket.listener.path.recovery.requested",
            stage: "socket_file_health_check",
            errnoCode: pathStatus.errnoCode,
            extra: recoveryData
        )

        let recoveryTask = Task { @MainActor [weak self, recoveryPath] in
            await Task.yield()
            guard !Task.isCancelled, let self else {
                return
            }
            defer {
                self.clearSocketFileRecoveryTask(generation: snapshot.activeGeneration)
            }
            guard !Task.isCancelled else {
                return
            }
            self.recoverSocketListenerAfterSocketFileLoss(
                generation: snapshot.activeGeneration,
                recoveryPath: recoveryPath,
                shouldUnlinkNonSocketReplacement: shouldUnlinkNonSocketReplacement,
                nonSocketReplacementIdentity: nonSocketReplacementIdentity
            )
        }
        let recoveryTaskInstallResult = replaceSocketFileRecoveryTask(
            recoveryTask,
            generation: snapshot.activeGeneration
        )
        if recoveryTaskInstallResult.installed {
            recoveryTaskInstallResult.previousTask?.cancel()
        } else {
            recoveryTask.cancel()
            clearPendingSocketFileRecovery(generation: snapshot.activeGeneration)
        }
    }

    func recoverSocketListenerAfterSocketFileLoss(
        generation: UInt64,
        recoveryPath: String,
        shouldUnlinkNonSocketReplacement: Bool,
        nonSocketReplacementIdentity: SocketPathIdentity?
    ) {
        guard let tabManager else {
            clearPendingSocketFileRecovery(generation: generation)
            return
        }

        guard let restart = takeSocketFileRecoveryRestart(generation: generation) else {
            return
        }

        sentryBreadcrumb(
            "socket.listener.path.recovery.restarting",
            category: "socket",
            data: socketListenerEventData(
                stage: "socket_file_recovery_restart",
                extra: [
                    "generation": generation,
                    "path": restart.path,
                    "recoveryPath": recoveryPath,
                    "mode": restart.mode.rawValue
                ]
            )
        )

        stop()
        if shouldUnlinkNonSocketReplacement {
            let replacementStatus = SocketPathProbe.observedStatus(path: recoveryPath, expectedIdentity: nil)
            if case .notSocket = replacementStatus,
               let nonSocketReplacementIdentity,
               SocketPathProbe.fileIdentity(path: recoveryPath) == nonSocketReplacementIdentity {
                SocketPathProbe.unlinkPathIfPresent(recoveryPath)
            } else {
                reportSocketListenerFailure(
                    message: "socket.listener.path.recovery.unlink_skipped",
                    stage: "socket_file_recovery_restart",
                    errnoCode: replacementStatus.errnoCode,
                    extra: [
                        "generation": generation,
                        "path": recoveryPath,
                        "pathStatus": replacementStatus.debugLabel
                    ]
                )
            }
        }
        let didRestart = start(
            tabManager: tabManager,
            socketPath: recoveryPath,
            accessMode: restart.mode,
            preserveAcceptFailureStreak: true
        )
        if !didRestart {
            let failedPath = listenerStateSnapshot().socketPath
            reportSocketListenerFailure(
                message: "socket.listener.path.recovery.restart_failed",
                stage: "socket_file_recovery_restart",
                extra: [
                    "path": failedPath,
                    "requestedPath": recoveryPath,
                    "mode": restart.mode.rawValue,
                    "generation": generation
                ]
            )
            startSocketFileRecoveryRetryWatcher(
                socketPath: recoveryPath,
                accessMode: restart.mode
            )
        }
    }
}

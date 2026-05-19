import CMUXSocketPathDomain
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
        let fd = open(directoryPath, O_EVTONLY)
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

        var shouldStartSource = false
        let previousSource = withListenerState { () -> DispatchSourceFileSystemObject? in
            guard isRunning,
                  serverSocket == snapshot.serverSocket,
                  socketPath == snapshot.socketPath else {
                return nil
            }
            let previousSource = socketPathWatchSource
            socketPathWatchSource = source
            shouldStartSource = true
            return previousSource
        }
        source.resume()
        if shouldStartSource {
            previousSource?.cancel()
        } else {
            source.cancel()
        }
    }

    nonisolated func performSocketFileHealthCheck() {
        let snapshot = listenerStateSnapshot()
        guard snapshot.isRunning,
              snapshot.acceptLoopAlive,
              snapshot.serverSocket >= 0,
              !snapshot.listenerStartInProgress else {
            return
        }

        let observedPathStatus = SocketPathProbe.observedStatus(
            path: snapshot.socketPath,
            expectedIdentity: snapshot.boundSocketPathIdentity
        )
        let pathStatus: SocketPathOwnershipStatus
        if observedPathStatus == .socketFileChanged {
            pathStatus = socketPathOwnershipStatus(path: snapshot.socketPath)
        } else {
            pathStatus = observedPathStatus
        }
        let recoveryPath: String
        let shouldUnlinkNonSocketReplacement: Bool
        let ownerPid = pathStatus.ownerPid
        if case .ownedByOtherProcess(let ownerPid) = pathStatus {
            let configuredPath = SocketControlSettings.socketPath()
            if let fallbackPath = Self.fallbackSocketPathAfterBindFailure(
                requestedPath: snapshot.socketPath,
                stage: "existing_socket_owned_by_other_process",
                errnoCode: EADDRINUSE
            ),
                fallbackPath != snapshot.socketPath {
                recoveryPath = fallbackPath
                shouldUnlinkNonSocketReplacement = false
            } else if configuredPath != snapshot.socketPath {
                recoveryPath = configuredPath
                shouldUnlinkNonSocketReplacement = false
            } else {
                reportSocketListenerFailure(
                    message: "socket.listener.path.owned_by_other_process",
                    stage: "socket_file_health_check",
                    extra: [
                        "pathStatus": pathStatus.debugLabel,
                        "ownerPid": Int(ownerPid),
                        "generation": snapshot.activeGeneration
                    ]
                )
                return
            }
        } else if case .connectFailed(let errnoCode) = pathStatus,
                  errnoCode != ECONNREFUSED,
                  errnoCode != ENOENT {
            guard let fallbackPath = Self.fallbackSocketPathAfterBindFailure(
                requestedPath: snapshot.socketPath,
                stage: "existing_socket_connect_failed",
                errnoCode: errnoCode
            ),
                fallbackPath != snapshot.socketPath else {
                reportSocketListenerFailure(
                    message: "socket.listener.path.recovery.skipped",
                    stage: "socket_file_health_check",
                    errnoCode: errnoCode,
                    extra: [
                        "pathStatus": pathStatus.debugLabel,
                        "generation": snapshot.activeGeneration,
                        "reason": "no_safe_recovery_path"
                    ]
                )
                return
            }
            recoveryPath = fallbackPath
            shouldUnlinkNonSocketReplacement = false
        } else {
            guard pathStatus.shouldAttemptListenerRecovery else {
                return
            }
            recoveryPath = snapshot.socketPath
            if case .notSocket = pathStatus {
                shouldUnlinkNonSocketReplacement = true
            } else {
                shouldUnlinkNonSocketReplacement = false
            }
        }

        let shouldScheduleRecovery = withListenerState {
            guard isRunning,
                  acceptLoopAlive,
                  serverSocket == snapshot.serverSocket,
                  activeAcceptLoopGeneration == snapshot.activeGeneration,
                  pendingSocketFileRecoveryGeneration == nil else {
                return false
            }
            pendingSocketFileRecoveryGeneration = snapshot.activeGeneration
            return true
        }
        guard shouldScheduleRecovery else {
            return
        }

        var recoveryData: [String: Any] = [
            "pathStatus": pathStatus.debugLabel,
            "generation": snapshot.activeGeneration,
            "recoveryPath": recoveryPath
        ]
        if let ownerPid {
            recoveryData["ownerPid"] = Int(ownerPid)
        }
        reportSocketListenerFailure(
            message: "socket.listener.path.recovery.requested",
            stage: "socket_file_health_check",
            errnoCode: pathStatus.errnoCode,
            extra: recoveryData
        )

        Task { @MainActor [weak self, recoveryPath] in
            self?.recoverSocketListenerAfterSocketFileLoss(
                generation: snapshot.activeGeneration,
                recoveryPath: recoveryPath,
                shouldUnlinkNonSocketReplacement: shouldUnlinkNonSocketReplacement
            )
        }
    }

    func recoverSocketListenerAfterSocketFileLoss(
        generation: UInt64,
        recoveryPath: String,
        shouldUnlinkNonSocketReplacement: Bool
    ) {
        guard let tabManager else {
            withListenerState {
                if pendingSocketFileRecoveryGeneration == generation {
                    pendingSocketFileRecoveryGeneration = nil
                }
            }
            return
        }

        guard let restart = withListenerState({ () -> (path: String, mode: SocketControlMode)? in
            guard pendingSocketFileRecoveryGeneration == generation,
                  activeAcceptLoopGeneration == generation else {
                return nil
            }
            pendingSocketFileRecoveryGeneration = nil
            return (socketPath, accessMode)
        }) else {
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
            SocketPathProbe.unlinkPathIfPresent(recoveryPath)
        }
        start(
            tabManager: tabManager,
            socketPath: recoveryPath,
            accessMode: restart.mode,
            preserveAcceptFailureStreak: true
        )
        if !listenerStateSnapshot().isRunning {
            reportSocketListenerFailure(
                message: "socket.listener.path.recovery.restart_failed",
                stage: "socket_file_recovery_restart",
                extra: [
                    "path": recoveryPath,
                    "mode": restart.mode.rawValue,
                    "generation": generation
                ]
            )
        }
    }
}

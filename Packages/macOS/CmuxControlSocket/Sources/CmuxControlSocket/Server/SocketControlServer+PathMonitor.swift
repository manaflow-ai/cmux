internal import Darwin
internal import Foundation

extension SocketControlServer {
    /// Watches the socket path's parent directory and reports when the bound
    /// socket file disappears, so the host can restart the listener.
    ///
    /// `DispatchSource.makeFileSystemObjectSource` carve-out: file watching
    /// with no Foundation async equivalent. The event handler is state-free:
    /// it validates against the published snapshot and stats the filesystem
    /// on the listener queue, never touching main-actor state. The host's
    /// restart path re-validates with
    /// ``shouldRestartForMissingPath(path:generation:)`` before acting, so a
    /// stale report is harmless.
    func startSocketPathMonitor(path: String, generation: UInt64) {
        let directoryPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let fd = open(directoryPath, O_EVTONLY)
        guard fd >= 0 else {
            events.breadcrumb(
                "socket.listener.path_monitor.failed",
                socketListenerEventData(
                    stage: "path_monitor_open",
                    errnoCode: errno,
                    extra: [
                        "generation": generation,
                        "directory": directoryPath,
                    ]
                )
            )
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: socketListenerQueue
        )
        source.setEventHandler { @Sendable [weak self] in
            self?.handleSocketPathDirectoryEvent(path: path, generation: generation)
        }
        source.setCancelHandler { @Sendable in
            close(fd)
        }

        let previousSource = withListenerState { state -> (any DispatchSourceFileSystemObject)? in
            guard state.isRunning,
                  state.activeAcceptLoopGeneration == generation,
                  state.socketPath == path else {
                return source
            }
            let previous = state.socketPathMonitorSource
            state.socketPathMonitorSource = source
            return previous
        }

        if previousSource === source {
            source.cancel()
            source.resume()
            return
        }

        previousSource?.cancel()
        source.resume()
    }

    private nonisolated func handleSocketPathDirectoryEvent(path: String, generation: UInt64) {
        let snapshot = listenerStateSnapshot()
        guard snapshot.isRunning,
              snapshot.activeGeneration == generation,
              snapshot.socketPath == path else {
            return
        }
        guard !transport.pathExists(path, matching: snapshot.boundSocketPathIdentity) else { return }

        reportSocketListenerFailure(
            message: "socket.listener.path.missing",
            stage: "path_monitor",
            extra: ["generation": generation]
        )

        events.pathMissingDetected(path, generation)
    }

    /// Re-validates a ``SocketControlServerEvents/pathMissingDetected`` report
    /// from the host's restart context. Reads the published snapshot — every
    /// consulted field is mirror-published, so the check never waits on
    /// anything (the legacy check was a bare lock read with the same
    /// last-committed-state semantics).
    /// - Parameters:
    ///   - path: The path the monitor reported missing.
    ///   - generation: The generation the report was issued under.
    /// - Returns: `true` when the listener is still running that generation on
    ///   that path and the socket file is still gone, so a stop/start restart
    ///   is warranted.
    public nonisolated func shouldRestartForMissingPath(path: String, generation: UInt64) -> Bool {
        let snapshot = listenerStateSnapshot()
        return snapshot.isRunning &&
            snapshot.activeGeneration == generation &&
            snapshot.socketPath == path &&
            !transport.pathExists(path, matching: snapshot.boundSocketPathIdentity)
    }
}

import Darwin
import Foundation

extension CLIError {
    init(message: String, exitCode: SSHPTYAttachExitCode) {
        self.init(message: message, exitCode: exitCode.rawValue)
    }
}

extension CMUXCLI {
    /// True when a persistent attach wrapper owns retrying a 254|255 failure.
    /// Persistent wrappers export `CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY=1`;
    /// direct invocations leave it unset, so failures there always clean up.
    func sshPTYAttachWrapperRetryPending() -> Bool {
        (ProcessInfo.processInfo.environment["CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    func cleanupFailedSSHPTYAttach(
        client: SocketClient,
        workspaceId: String,
        surfaceID: String?,
        sessionID: String,
        lifecycleID: String,
        attachmentID: String,
        attachmentToken: String,
        retireLifecycle: Bool,
        clearLocalSurface: Bool
    ) {
        let normalizedAttachmentToken = attachmentToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedAttachmentToken.isEmpty {
            var detachParams: [String: Any] = [
                "workspace_id": workspaceId,
                "session_id": sessionID,
                "attachment_id": attachmentID,
                "attachment_token": normalizedAttachmentToken,
            ]
            if let surfaceID {
                detachParams["surface_id"] = surfaceID
                detachParams["allow_moved_surface"] = true
            }
            _ = try? client.sendV2(method: "workspace.remote.pty_detach", params: detachParams)
        }
        if retireLifecycle {
            var lifecycleParams: [String: Any] = [
                "workspace_id": workspaceId, "session_id": sessionID,
                "lifecycle_id": lifecycleID, "acknowledge_lifecycle": true,
            ]
            if let surfaceID {
                lifecycleParams["surface_id"] = surfaceID
                lifecycleParams["allow_moved_surface"] = true
            }
            _ = try? client.sendV2(method: "workspace.remote.pty_sessions", params: lifecycleParams)
        }
        guard clearLocalSurface else { return }
        guard let surfaceID else { return }
        _ = try? client.sendV2(method: "workspace.remote.pty_attach_end", params: [
            "workspace_id": workspaceId,
            "surface_id": surfaceID,
            "session_id": sessionID,
        ])
    }

    func sshPTYBridgeParams(
        workspaceId: String,
        surfaceID: String?,
        sessionID: String,
        lifecycleID: String,
        attachmentID: String,
        command: String?,
        requireExisting: Bool
    ) -> [String: Any] {
        var params: [String: Any] = [
            "workspace_id": workspaceId,
            "session_id": sessionID,
            "lifecycle_id": lifecycleID,
            "attachment_id": attachmentID,
            "command": command ?? "",
            "require_existing": requireExisting,
        ]
        if let surfaceID {
            params["surface_id"] = surfaceID
            params["allow_moved_surface"] = true
        }
        return params
    }

    /// Reconciles one bridge end against the tunnel-owned logical generation.
    @discardableResult
    func reconcileSSHPTYBridgeEnd(
        client: SocketClient,
        workspaceId: String,
        surfaceID: String?,
        sessionID: String,
        lifecycleID: String,
        intentionalOnly: Bool
    ) throws -> Bool {
        let reconciliationFailure = "ssh-pty-attach: bridge closed before remote PTY exit could be confirmed"
        let response: [String: Any]
        do {
            var params: [String: Any] = [
                "workspace_id": workspaceId,
                "session_id": sessionID,
                "lifecycle_id": lifecycleID,
                "acknowledge_lifecycle_if_session_absent": !intentionalOnly,
            ]
            if let surfaceID {
                params["surface_id"] = surfaceID
                params["allow_moved_surface"] = true
            }
            response = try client.sendV2(method: "workspace.remote.pty_sessions", params: params)
        } catch {
            throw CLIError(
                message: "\(reconciliationFailure): \(userFacingRemotePTYErrorMessage(error))",
                exitCode: SSHPTYAttachExitCode.retryableTransient
            )
        }

        let requestedLifecycle = (response["requested_session_lifecycle"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let intentionalCleanup = requestedLifecycle == "intentional_cleanup_requested" ||
            requestedLifecycle == "intentionally_closed"
        guard let sessions = response["sessions"] as? [[String: Any]] else {
            throw CLIError(message: reconciliationFailure, exitCode: SSHPTYAttachExitCode.retryableTransient)
        }
        let errors: [[String: Any]]
        if let rawErrors = response["errors"] {
            guard let parsedErrors = rawErrors as? [[String: Any]] else {
                throw CLIError(message: reconciliationFailure, exitCode: SSHPTYAttachExitCode.retryableTransient)
            }
            errors = parsedErrors
        } else {
            errors = []
        }
        if !intentionalCleanup, !errors.isEmpty {
            throw CLIError(
                message: "\(reconciliationFailure)\n\(sshSessionListFailureMessage(errors))",
                exitCode: SSHPTYAttachExitCode.retryableTransient
            )
        }
        if intentionalOnly, !intentionalCleanup { return false }

        let sessionStillRunning = sessions.contains {
            (($0["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") == sessionID
        }
        if !intentionalCleanup, sessionStillRunning {
            throw CLIError(
                message: "ssh-pty-attach: bridge closed while remote PTY session is still running",
                exitCode: SSHPTYAttachExitCode.bridgeClosedSessionRunning
            )
        }
        guard let surfaceID else { return true }
        do {
            _ = try client.sendV2(method: "workspace.remote.pty_attach_end", params: [
                "workspace_id": workspaceId,
                "surface_id": surfaceID,
                "session_id": sessionID,
            ])
        } catch {
            throw CLIError(
                message: "ssh-pty-attach: remote PTY exited but local session cleanup failed: \(userFacingRemotePTYErrorMessage(error))",
                exitCode: SSHPTYAttachExitCode.retryableTransient
            )
        }
        return true
    }

    func readSSHPTYBridgeReady(fd: Int32) throws -> String {
        let maxStatusBytes = 4096
        // Bound only the pre-ready status wait: a bridge that accepts the TCP
        // connection and then goes silent must not hang the attach (and its
        // wrapper retry loop) forever. The post-ready interactive fd stays
        // unbounded; idle sessions legitimately block on read.
        let deadline = Date().addingTimeInterval(sshPTYBridgeReadyTimeoutSeconds())
        var line = Data()
        var byte = [UInt8](repeating: 0, count: 1)
        while line.count < maxStatusBytes {
            try waitForSSHPTYBridgeReadable(fd: fd, deadline: deadline)
            let count = Darwin.read(fd, &byte, 1)
            if count > 0 {
                if byte[0] == 0x0A {
                    if let carriageIndex = line.lastIndex(of: 0x0D),
                       carriageIndex == line.index(before: line.endIndex) {
                        line.remove(at: carriageIndex)
                    }
                    guard let payload = try? JSONSerialization.jsonObject(with: line, options: []) as? [String: Any],
                          let type = payload["type"] as? String else {
                        throw CLIError(message: "ssh-pty-attach: invalid bridge status")
                    }
                    switch type {
                    case "ready":
                        return ((payload["attachment_token"] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
                    case "error":
                        let message = ((payload["message"] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                            ?? "remote PTY attach failed"
                        let code = (payload["code"] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        throw CLIError(
                            message: "ssh-pty-attach: \(message)",
                            exitCode: SSHPTYAttachExitCode.classifyBridgeEstablishmentFailure(
                                code: code,
                                message: message
                            )
                        )
                    default:
                        throw CLIError(message: "ssh-pty-attach: invalid bridge status")
                    }
                }
                line.append(byte[0])
            } else if count == 0 {
                throw CLIError(
                    message: "ssh-pty-attach: bridge closed before ready",
                    exitCode: SSHPTYAttachExitCode.retryableTransient
                )
            } else if errno != EINTR {
                throw CLIError(
                    message: "ssh-pty-attach: bridge read failed",
                    exitCode: SSHPTYAttachExitCode.retryableTransient
                )
            }
        }
        throw CLIError(message: "ssh-pty-attach: bridge status exceeded \(maxStatusBytes) bytes")
    }

    /// Ceiling for the bridge ready/error status wait. Defaults to 185s,
    /// matching the `wait_for_ready` RPC response timeout in `runSSHPTYAttach`.
    private func sshPTYBridgeReadyTimeoutSeconds() -> TimeInterval {
        let defaultTimeout: TimeInterval = 185
        guard let raw = ProcessInfo.processInfo.environment["CMUX_SSH_PTY_BRIDGE_READY_TIMEOUT_SECONDS"],
              let value = TimeInterval(raw), value > 0 else {
            return defaultTimeout
        }
        return value
    }

    private func waitForSSHPTYBridgeReadable(fd: Int32, deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw CLIError(
                    message: "ssh-pty-attach: timed out waiting for bridge status",
                    exitCode: SSHPTYAttachExitCode.retryableTransient
                )
            }
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let timeoutMs = Int32(min(remaining * 1000, 60_000).rounded(.up))
            let result = poll(&pollFD, 1, timeoutMs)
            if result > 0 { return }
            if result < 0 && errno != EINTR {
                throw CLIError(
                    message: "ssh-pty-attach: bridge read failed",
                    exitCode: SSHPTYAttachExitCode.retryableTransient
                )
            }
            // result == 0 (poll interval elapsed) or EINTR: recheck the deadline.
        }
    }

    func connectLoopbackTCP(host: String, port: Int) throws -> Int32 {
        guard host == "127.0.0.1" || host == "localhost" else {
            throw CLIError(message: "ssh-pty-attach: bridge host must be loopback")
        }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CLIError(message: "ssh-pty-attach: failed to create bridge socket")
        }
        do {
            try configureCLISocketNoSIGPIPE(
                fileDescriptor: fd,
                failureMessage: "ssh-pty-attach: failed to disable SIGPIPE on bridge socket"
            )
        } catch {
            Darwin.close(fd)
            throw error
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw CLIError(
                message: "ssh-pty-attach: failed to connect to bridge",
                exitCode: SSHPTYAttachExitCode.retryableTransient
            )
        }
        return fd
    }
}

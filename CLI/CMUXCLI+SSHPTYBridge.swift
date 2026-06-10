import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - SSH PTY attach bridge
extension CMUXCLI {
    func runSSHPTYAttach(commandArgs: [String], client: SocketClient) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (sessionIDOpt, rem1) = parseOption(rem0, name: "--session-id")
        let (attachmentIDOpt, rem2) = parseOption(rem1, name: "--attachment-id")
        let (commandB64Opt, rem3) = parseOption(rem2, name: "--command-b64")
        let waitForReady = rem3.contains("--wait")
        let requireExisting = rem3.contains("--require-existing")
        let remaining = rem3.filter { $0 != "--wait" && $0 != "--require-existing" }
        if let unknown = remaining.first(where: { Self.isFlagToken($0) }) {
            throw CLIError(message: "ssh-pty-attach: unknown flag '\(unknown)'")
        }
        guard remaining.isEmpty else {
            throw CLIError(message: "Usage: cmux ssh-pty-attach --workspace <workspace> --session-id <id> [--attachment-id <id>] [--command-b64 <base64>] [--require-existing]")
        }
        let workspaceRaw = workspaceOpt ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        guard let workspaceRaw,
              let workspaceId = try normalizeWorkspaceHandle(workspaceRaw, client: client),
              !workspaceId.isEmpty else {
            throw CLIError(message: "ssh-pty-attach requires --workspace or CMUX_WORKSPACE_ID")
        }
        guard let sessionID = sessionIDOpt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            throw CLIError(message: "ssh-pty-attach requires --session-id <id>")
        }
        let environmentSurfaceID = Self.normalizedEnvValue(ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"])
        let explicitAttachmentID = Self.normalizedEnvValue(attachmentIDOpt)
        let surfaceID = environmentSurfaceID ?? (explicitAttachmentID.flatMap { UUID(uuidString: $0) == nil ? nil : $0 })
        let attachmentID = explicitAttachmentID ?? environmentSurfaceID ?? UUID().uuidString.lowercased()
        let command: String? = try commandB64Opt.flatMap { encoded in
            guard let data = Data(base64Encoded: encoded),
                  var decoded = String(data: data, encoding: .utf8) else {
                throw CLIError(message: "ssh-pty-attach: --command-b64 must be valid UTF-8 base64")
            }
            decoded = decoded
                .replacingOccurrences(of: "__CMUX_WORKSPACE_ID__", with: workspaceId)
                .replacingOccurrences(
                    of: "__CMUX_SURFACE_ID__",
                    with: ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] ?? ""
                )
            return decoded
        }
        var bridgeReachedReady = false
        var attachFinished = false
        var attachmentToken = ""
        defer {
            if !attachFinished {
                cleanupFailedSSHPTYAttach(
                    client: client,
                    workspaceId: workspaceId,
                    surfaceID: surfaceID,
                    sessionID: sessionID,
                    attachmentID: attachmentID,
                    attachmentToken: attachmentToken,
                    clearLocalSurface: !bridgeReachedReady
                )
            }
        }

        let bridge: [String: Any]
        do {
            var bridgeParams = sshPTYBridgeParams(
                workspaceId: workspaceId,
                surfaceID: surfaceID,
                sessionID: sessionID,
                attachmentID: attachmentID,
                command: command,
                requireExisting: requireExisting
            )
            if waitForReady {
                bridgeParams["wait_for_ready"] = true
            }
            bridge = try client.sendV2(
                method: "workspace.remote.pty_bridge",
                params: bridgeParams,
                responseTimeout: waitForReady ? 185 : nil
            )
        } catch {
            throw CLIError(message: "ssh-pty-attach: \(userFacingRemotePTYErrorMessage(error))")
        }
        var connectedFD: Int32?
        let controlSocketLock = NSLock()
        do {
            let host = (bridge["host"] as? String) ?? "127.0.0.1"
            guard let port = cliStrictInt(bridge["port"]), port > 0, port <= 65535 else {
                throw CLIError(message: "ssh-pty-attach: bridge did not return a valid port")
            }
            guard let token = bridge["token"] as? String, !token.isEmpty else {
                throw CLIError(message: "ssh-pty-attach: bridge did not return a token")
            }

            connectedFD = try connectLoopbackTCP(host: host, port: port)
            let fd = connectedFD!
            let size = currentCLITerminalSize()
            var handshakeData = try JSONSerialization.data(withJSONObject: [
                "token": token,
                "cols": size.cols,
                "rows": size.rows,
                "client_pid": Int(getpid()),
            ], options: [])
            handshakeData.append(0x0A)
            try writeAll(fd: fd, data: handshakeData)
            attachmentToken = try readSSHPTYBridgeReady(fd: fd)
            bridgeReachedReady = true
        } catch {
            if let connectedFD {
                Darwin.close(connectedFD)
            }
            throw error
        }
        let fd = connectedFD!
        defer { Darwin.close(fd) }

        let rawMode = TerminalRawMode()
        defer { rawMode?.restore() }
        let resizeSource = startSSHPTYResizeSource(
            client: client,
            workspaceId: workspaceId,
            surfaceID: surfaceID,
            sessionID: sessionID,
            attachmentID: attachmentID,
            attachmentToken: attachmentToken,
            socketLock: controlSocketLock
        )
        defer { resizeSource.cancel() }

        DispatchQueue.global(qos: .userInteractive).async {
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                if count > 0 {
                    do {
                        try self.writeAll(fd: fd, data: Data(buffer.prefix(count)))
                    } catch {
                        _ = shutdown(fd, SHUT_WR)
                        return
                    }
                } else if count == 0 {
                    _ = shutdown(fd, SHUT_WR)
                    return
                } else if errno != EINTR {
                    _ = shutdown(fd, SHUT_WR)
                    return
                }
            }
        }

        var outputBuffer = [UInt8](repeating: 0, count: 32768)
        while true {
            let count = Darwin.read(fd, &outputBuffer, outputBuffer.count)
            if count > 0 {
                FileHandle.standardOutput.write(Data(outputBuffer.prefix(count)))
            } else if count == 0 {
                resizeSource.cancel()
                try handleSSHPTYBridgeEOF(
                    client: client,
                    workspaceId: workspaceId,
                    surfaceID: surfaceID,
                    sessionID: sessionID,
                    attachmentID: attachmentID,
                    socketLock: controlSocketLock
                )
                attachFinished = true
                return
            } else if errno != EINTR {
                if sshPTYBridgeReadErrorIsEOF(errno) {
                    resizeSource.cancel()
                    try handleSSHPTYBridgeEOF(
                        client: client,
                        workspaceId: workspaceId,
                        surfaceID: surfaceID,
                        sessionID: sessionID,
                        attachmentID: attachmentID,
                        socketLock: controlSocketLock
                    )
                    attachFinished = true
                    return
                }
                throw CLIError(message: "ssh-pty-attach: bridge read failed")
            }
        }
    }

    private func cleanupFailedSSHPTYAttach(
        client: SocketClient,
        workspaceId: String,
        surfaceID: String?,
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
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
        guard clearLocalSurface else { return }
        guard let surfaceID else { return }
        _ = try? client.sendV2(method: "workspace.remote.pty_attach_end", params: [
            "workspace_id": workspaceId,
            "surface_id": surfaceID,
            "session_id": sessionID,
        ])
    }

    private func sshPTYBridgeReadErrorIsEOF(_ errnoValue: Int32) -> Bool {
        switch errnoValue {
        case ECONNRESET, ECONNABORTED, ENOTCONN:
            return true
        default:
            return false
        }
    }

    private func handleSSHPTYBridgeEOF(
        client: SocketClient,
        workspaceId: String,
        surfaceID: String?,
        sessionID: String,
        attachmentID: String,
        socketLock: NSLock
    ) throws {
        socketLock.lock()
        defer { socketLock.unlock() }

        let response: [String: Any]
        do {
            var params: [String: Any] = [
                "workspace_id": workspaceId,
            ]
            if let surfaceID {
                params["surface_id"] = surfaceID
                params["session_id"] = sessionID
                params["allow_moved_surface"] = true
            }
            response = try client.sendV2(method: "workspace.remote.pty_sessions", params: params)
        } catch {
            throw CLIError(
                message: "ssh-pty-attach: bridge closed before remote PTY exit could be confirmed: \(userFacingRemotePTYErrorMessage(error))",
                exitCode: 255
            )
        }

        let errors = response["errors"] as? [[String: Any]] ?? []
        if !errors.isEmpty {
            throw CLIError(
                message: "ssh-pty-attach: bridge closed before remote PTY exit could be confirmed\n\(sshSessionListFailureMessage(errors))",
                exitCode: 255
            )
        }

        let sessions = response["sessions"] as? [[String: Any]] ?? []
        let sessionStillRunning = sessions.contains {
            (($0["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") == sessionID
        }
        if sessionStillRunning {
            throw CLIError(
                message: "ssh-pty-attach: bridge closed while remote PTY session is still running",
                exitCode: 254
            )
        }

        guard let surfaceID else {
            return
        }

        do {
            _ = try client.sendV2(method: "workspace.remote.pty_attach_end", params: [
                "workspace_id": workspaceId,
                "surface_id": surfaceID,
                "session_id": sessionID,
            ])
        } catch {
            throw CLIError(
                message: "ssh-pty-attach: remote PTY exited but local session cleanup failed: \(userFacingRemotePTYErrorMessage(error))",
                exitCode: 255
            )
        }
    }

    private func sshPTYBridgeParams(
        workspaceId: String,
        surfaceID: String?,
        sessionID: String,
        attachmentID: String,
        command: String?,
        requireExisting: Bool
    ) -> [String: Any] {
        var params: [String: Any] = [
            "workspace_id": workspaceId,
            "session_id": sessionID,
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

    func userFacingRemotePTYErrorMessage(_ value: Any?) -> String {
        if let error = value as? Error {
            return userFacingRemotePTYErrorMessage(String(describing: error))
        }
        return userFacingRemotePTYErrorMessage(debugString(value) ?? "unknown error")
    }

    func userFacingRemotePTYErrorMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "remote PTY operation failed" }
        let lowered = trimmed.lowercased()
        if lowered.contains("missing required capability") ||
            lowered.contains("pty.session") ||
            lowered.contains("pty.write.notification") ||
            lowered.contains("method_not_found") {
            return "remote daemon does not support persistent SSH PTY sessions; reconnect the remote workspace to update cmux"
        }
        if lowered.contains("pty_session_not_found") ||
            (lowered.contains("persistent ssh pty session") && lowered.contains("not running")) ||
            (lowered.contains("persistent pty session") && lowered.contains("not running")) {
            return "persistent SSH PTY session is no longer running"
        }
        if lowered.contains("pty_input_queue_full") || lowered.contains("pty input queue is full") {
            return "remote PTY input is temporarily backed up"
        }
        if lowered.contains("remote connection is not active") {
            return "remote connection is not active"
        }
        if lowered.contains("remote daemon is not ready") || lowered.contains("remote daemon tunnel is not ready") {
            return "remote daemon is not ready"
        }
        if lowered.contains("missing workspace_id in ssh pty session list response") {
            return "missing workspace_id in SSH PTY session list response"
        }
        if lowered.contains("missing session_id in ssh pty session list response") {
            return "missing session_id in SSH PTY session list response"
        }
        if lowered.contains("timed out") || lowered.contains("timeout") {
            return "remote daemon did not respond in time"
        }
        // Surface the daemon's PTY-allocation diagnostic verbatim (it names the
        // failing device and the devpts/ptmxmode cause) instead of collapsing it
        // into a generic message. Key off the daemon's stable marker only, so an
        // unrelated error that merely mentions a device path is not leaked. The
        // peer branches in this CLI helper return plain English, so this branch
        // does too. See issue #5185.
        if lowered.contains("could not allocate a remote pty") {
            return trimmed
        }
        return "remote PTY operation failed"
    }

    private func readSSHPTYBridgeReady(fd: Int32) throws -> String {
        let maxStatusBytes = 4096
        var line = Data()
        var byte = [UInt8](repeating: 0, count: 1)
        while line.count < maxStatusBytes {
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
                        throw CLIError(message: "ssh-pty-attach: \(message)")
                    default:
                        throw CLIError(message: "ssh-pty-attach: invalid bridge status")
                    }
                }
                line.append(byte[0])
            } else if count == 0 {
                throw CLIError(message: "ssh-pty-attach: bridge closed before ready")
            } else if errno != EINTR {
                throw CLIError(message: "ssh-pty-attach: bridge read failed")
            }
        }
        throw CLIError(message: "ssh-pty-attach: bridge status exceeded \(maxStatusBytes) bytes")
    }

    private func startSSHPTYResizeSource(
        client: SocketClient,
        workspaceId: String,
        surfaceID: String?,
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        socketLock: NSLock
    ) -> DispatchSourceSignal {
        signal(SIGWINCH, SIG_IGN)
        let source = DispatchSource.makeSignalSource(
            signal: SIGWINCH,
            queue: DispatchQueue(label: "com.cmux.ssh-pty.resize")
        )
        source.setEventHandler {
            let size = self.currentCLITerminalSize()
            socketLock.lock()
            defer { socketLock.unlock() }
            var params: [String: Any] = [
                "workspace_id": workspaceId,
                "session_id": sessionID,
                "attachment_id": attachmentID,
                "attachment_token": attachmentToken,
                "cols": size.cols,
                "rows": size.rows,
            ]
            if let surfaceID {
                params["surface_id"] = surfaceID
                params["allow_moved_surface"] = true
            }
            _ = try? client.sendV2(method: "workspace.remote.pty_resize", params: params)
        }
        source.resume()
        return source
    }

    private func connectLoopbackTCP(host: String, port: Int) throws -> Int32 {
        guard host == "127.0.0.1" || host == "localhost" else {
            throw CLIError(message: "ssh-pty-attach: bridge host must be loopback")
        }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CLIError(message: "ssh-pty-attach: failed to create bridge socket")
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
            throw CLIError(message: "ssh-pty-attach: failed to connect to bridge")
        }
        return fd
    }

    private func cliStrictInt(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            guard double.rounded(.towardZero) == double else { return nil }
            return number.intValue
        }
        return nil
    }

    private func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var remaining = rawBuffer.count
            var cursor = base
            while remaining > 0 {
                let written = Darwin.write(fd, cursor, remaining)
                if written > 0 {
                    remaining -= written
                    cursor = cursor.advanced(by: written)
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    throw CLIError(message: "ssh-pty-attach: bridge write failed")
                }
            }
        }
    }

    func runSSHSessionEnd(commandArgs: [String], client: SocketClient) throws {
        guard let relayPortRaw = optionValue(commandArgs, name: "--relay-port"),
              let relayPort = Int(relayPortRaw),
              relayPort > 0 else {
            throw CLIError(message: "ssh-session-end requires --relay-port <port>")
        }
        let workspaceRaw = optionValue(commandArgs, name: "--workspace") ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        let surfaceRaw = optionValue(commandArgs, name: "--surface") ?? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]
        guard let workspaceRaw,
              let workspaceId = try normalizeWorkspaceHandle(workspaceRaw, client: client),
              !workspaceId.isEmpty else {
            throw CLIError(message: "ssh-session-end requires --workspace or CMUX_WORKSPACE_ID")
        }
        guard let surfaceRaw,
              let surfaceId = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceId),
              !surfaceId.isEmpty else {
            throw CLIError(message: "ssh-session-end requires --surface or CMUX_SURFACE_ID")
        }
        _ = try client.sendV2(method: "workspace.remote.terminal_session_end", params: [
            "workspace_id": workspaceId,
            "surface_id": surfaceId,
            "relay_port": relayPort,
        ])
    }

}

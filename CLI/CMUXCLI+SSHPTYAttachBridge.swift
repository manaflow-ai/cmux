import Darwin
import Foundation

extension CLIError {
    init(message: String, exitCode: SSHPTYAttachExitCode) {
        self.init(message: message, exitCode: exitCode.rawValue)
    }
}

extension CMUXCLI {
    func cleanupFailedSSHPTYAttach(
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

    func sshPTYBridgeParams(
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

    func readSSHPTYBridgeReady(fd: Int32) throws -> String {
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

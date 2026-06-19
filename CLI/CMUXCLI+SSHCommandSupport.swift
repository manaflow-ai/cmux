import Foundation
import Darwin
import Dispatch

extension CMUXCLI {
    internal func openSSHLocalCommandValue(shellScript: String?) -> String? {
        guard let shellScript else { return nil }
        let trimmed = shellScript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return openSSHCommandOptionValue(posixShellCommand(trimmed))
    }

    internal func openSSHRemoteCommandValue(shellScript: String) -> String {
        openSSHCommandOptionValue(posixShellCommand(shellScript))
    }

    internal func posixShellCommand(_ shellScript: String) -> String {
        "/bin/sh -c " + shellQuote(shellScript)
    }

    internal func openSSHCommandOptionValue(_ command: String) -> String {
        command.replacingOccurrences(of: "%", with: "%%")
    }

    /// Joins self-delimiting POSIX shell snippets with one space; this is not a general shell combiner.
    internal func combinedLocalShellScript(_ parts: [String?]) -> String? {
        let filtered = parts.compactMap { raw -> String? in
            guard let raw else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard !filtered.isEmpty else { return nil }
        return filtered.joined(separator: " ")
    }

    func startSSHPTYResizeSource(
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
            self.sendSSHPTYResize(
                client: client,
                workspaceId: workspaceId,
                surfaceID: surfaceID,
                sessionID: sessionID,
                attachmentID: attachmentID,
                attachmentToken: attachmentToken,
                socketLock: socketLock
            )
        }
        source.resume()
        return source
    }

    /// Sends the current terminal size to the remote PTY over the control socket.
    func sendSSHPTYResize(
        client: SocketClient,
        workspaceId: String,
        surfaceID: String?,
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        socketLock: NSLock
    ) {
        // Keep the sample and send under one lock so an older sample cannot
        // overtake a fresher one and restore a stale remote PTY size.
        socketLock.lock()
        defer { socketLock.unlock() }
        let size = currentCLITerminalSize()
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
}

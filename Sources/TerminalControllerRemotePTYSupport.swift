import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSocketControl
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXWorkstream
import Foundation
import Bonsplit
import WebKit


// MARK: - Remote PTY socket target and user-facing error mapping
nonisolated struct RemotePTYSocketTarget {
    let controller: WorkspaceRemoteSessionController?
    let windowId: UUID?
    let windowRef: Any
    let workspaceId: UUID
    let workspaceRef: Any
    let workspaceTitle: String
}

nonisolated func remotePTYSessionListErrorIsUnsupportedDaemon(_ error: Error) -> Bool {
    let nsError = error as NSError
    guard nsError.domain == "cmux.remote.daemon.rpc", nsError.code == 14 else {
        return false
    }
    return error.localizedDescription
        .range(of: "pty.list failed (method_not_found)", options: [.caseInsensitive]) != nil
}

nonisolated func v2RemotePTYUserFacingErrorMessage(_ error: Error) -> String {
    v2RemotePTYUserFacingErrorMessage(error.localizedDescription)
}

nonisolated func v2RemotePTYUserFacingErrorMessage(_ message: String) -> String {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "remote PTY operation failed" }
    let lowered = trimmed.lowercased()
    if lowered.contains("missing required capability") ||
        lowered.contains("pty.session") ||
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
    return "remote PTY operation failed"
}


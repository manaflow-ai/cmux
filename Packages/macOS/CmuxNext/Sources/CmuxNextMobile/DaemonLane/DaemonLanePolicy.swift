public import Foundation

/// Authority filter for a phone spliced onto the local cmux-tui socket.
///
/// The daemon classes every Unix client as trusted-local (cloud-ios.md R9),
/// so the splice is the only place a phone's authority can be narrowed. The
/// policy is an allowlist: a command the phone may send is listed here, and
/// anything else (including commands added to the daemon later) is refused
/// before it reaches the socket. The phone keeps the ordinary control and
/// terminal authority a WebSocket client has, minus `local-admin`, provider
/// authority, and writes that would change the Mac frontend's own state.
public struct DaemonLanePolicy: Sendable {
    /// Largest request line the phone may send. Matches the daemon's
    /// authenticated WebSocket frame cap.
    public static let maximumLineBytes = 4 * 1024 * 1024

    /// The per-device projection subject (`ios-device:<device id>`). The
    /// phone may read and write only this `personal` projection.
    public let projectionSubject: String

    public init(deviceID: String) {
        projectionSubject = "ios-device:\(deviceID)"
    }

    /// Commands a phone may send. Grouped by purpose; every entry is a
    /// protocol-12 command the iOS `CmuxTUIControl` client or a reasonable
    /// phone frontend needs.
    public static let allowedCommands: Set<String> = [
        // Session and discovery (read-only).
        "identify", "ping", "server-stats", "set-client-info", "list-clients", "list-workspaces",
        "list-workspace-groups", "list-tab-groups", "list-saved-tab-groups", "list-notifications",
        "list-agents", "list-terminals", "resolve-terminal", "process-info", "machine-usage",
        "machine-listening-tcp", "ids", "export-layout", "subscribe", "terminal-events", "wait-for",
        // Terminal streams and input.
        "attach-surface", "vt-state", "read-screen", "read-scrollback", "scroll-surface", "send", "send-key",
        "copy", "clear-history", "set-terminal-idle-policy", "get-cell-pixels", "set-cell-pixels",
        // Geometry: per-client leases, released when the phone goes away.
        "set-client-sizing", "resize-surface", "release-surface-size", "resize-attached-view",
        "release-attached-view-size", "detach-attached-view",
        // Per-client focus (never moves the Mac's view).
        "client-focus", "report-focus",
        // Topology: the same authority the Mac frontend grants a signed-in phone today.
        "create-workspace", "new-workspace", "rename-workspace", "close-workspace", "move-workspace",
        "set-workspace-metadata", "create-workspace-group", "update-workspace-group", "delete-workspace-group",
        "move-workspace-group", "move-workspace-to-group", "create-terminal", "new-tab", "new-screen", "new-pane",
        "new-pane-right", "split", "set-ratio", "set-split-ratio", "set-viewport-pane-width", "undo-layout",
        "pane-neighbor", "focus-direction", "swap-pane", "zoom-pane", "close-surface", "close-pane", "close-screen",
        "close-terminal", "rename-pane", "rename-surface", "rename-screen", "focus-pane", "select-tab",
        "select-screen", "select-workspace", "move-tab", "move-terminal", "set-tab-pinned", "move-tab-to-workspace",
        "move-tab-to-split", "move-tab-to-column", "move-tab-to-new-workspace", "create-tab-group",
        "update-tab-group", "add-tabs-to-tab-group", "remove-tabs-from-tab-group", "move-tab-group",
        "move-tab-group-to-split", "move-tab-group-to-column", "move-tab-group-to-new-workspace",
        "ungroup-tab-group", "close-tab-group", "save-tab-group", "unsave-tab-group", "delete-saved-tab-group",
        "reopen-saved-tab-group", "ack-tab-notifications", "notify", "run", "create-surface-with-receipt",
        // Browser tabs the phone can already drive over SSH (CmuxTUIBrowser).
        "new-browser-tab", "browser-frame-presented", "browser-mouse", "browser-mouse-guarded", "browser-wheel",
        "browser-wheel-guarded", "browser-key", "browser-key-press", "browser-insert-text", "browser-navigate",
        "browser-back", "browser-forward", "browser-reload", "browser-activate",
        // Frontend projections: guarded per subject below.
        "get-frontend-projection", "put-frontend-projection",
    ]

    /// Outcome for one request line.
    public enum Verdict: Equatable, Sendable {
        /// Send the original line (unchanged bytes, newline appended by the splice).
        case forward
        /// Answer the phone with this v12 error line; never send to the daemon.
        case refuse(Data)
    }

    /// Judges one newline-stripped request line from the phone.
    public func evaluate(_ line: Data) -> Verdict {
        guard line.count <= Self.maximumLineBytes else {
            return .refuse(Self.errorLine(id: nil, code: "too_large", message: "request exceeds 4 MiB"))
        }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return .refuse(Self.errorLine(id: nil, code: "bad_request", message: "request is not a JSON object"))
        }
        let id = object["id"]
        guard let command = object["cmd"] as? String else {
            return .refuse(Self.errorLine(id: id, code: "bad_request", message: "missing cmd"))
        }
        guard Self.allowedCommands.contains(command) else {
            return .refuse(Self.errorLine(id: id, code: "forbidden",
                                          message: "\(command) is not available to a phone"))
        }
        if command == "get-frontend-projection" || command == "put-frontend-projection" {
            return projectionVerdict(object, id: id, write: command == "put-frontend-projection")
        }
        return .forward
    }

    private func projectionVerdict(_ object: [String: Any], id: Any?, write: Bool) -> Verdict {
        let scope = object["scope"] as? String
        let subject = object["subject_key"] as? String
        if scope == "personal", subject == projectionSubject { return .forward }
        // Reading a shared projection is harmless; writing one would change
        // every frontend's view, and another subject's personal projection
        // belongs to that frontend.
        if !write, scope != "personal" { return .forward }
        return .refuse(Self.errorLine(id: id, code: "forbidden",
                                      message: "phones may only use the personal projection \(projectionSubject)"))
    }

    /// A v12 error response line (no trailing newline).
    static func errorLine(id: Any?, code: String, message: String) -> Data {
        var response: [String: Any] = ["ok": false, "error": message, "error_code": code]
        response["id"] = id ?? NSNull()
        return (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data()
    }
}

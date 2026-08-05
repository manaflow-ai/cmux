import Foundation

extension TerminalController {
    /// `tui.frontend.attach_terminal` connects one broker session or reuses an
    /// existing window-local connection, then mounts the terminal as a native
    /// PTY-less Ghostty surface.
    nonisolated func v2CmuxTUIAttachTerminal(id: Any?, params: [String: Any]) -> String {
        guard let publicTerminalID = (params["terminal_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              Self.isValidCmuxTUIPublicTerminalID(publicTerminalID) else {
            return v2Error(
                id: id,
                code: "invalid_params",
                message: "terminal_id must be a term_ public terminal ID"
            )
        }

        let invitation = (params["invitation"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawSessionID = (params["session_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID = rawSessionID.flatMap(UUID.init(uuidString:))
        if rawSessionID?.isEmpty == false, sessionID == nil {
            return v2Error(
                id: id,
                code: "invalid_params",
                message: "session_id must be a UUID"
            )
        }
        let hasInvitation = invitation?.isEmpty == false
        let hasSession = sessionID != nil
        guard hasInvitation != hasSession else {
            return v2Error(
                id: id,
                code: "invalid_params",
                message: "provide exactly one of invitation or session_id"
            )
        }

        let rawTitle = (params["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if let rawTitle, !rawTitle.isEmpty {
            title = String(rawTitle.prefix(512))
        } else {
            title = String(localized: "cmuxTUI.terminal.defaultTitle", defaultValue: "cmux-tui")
        }
        let requestedFocus = v2Bool(params, "focus") ?? true

        return v2AsyncResultCall(id: id, timeoutSeconds: 45) {
            do {
                guard let tabManager = self.v2ResolveTabManager(params: params) else {
                    return .err(
                        code: "not_found",
                        message: "target cmux window not found",
                        data: nil
                    )
                }
                let focus = await MainActor.run {
                    self.v2FocusAllowed(requested: requestedFocus)
                }
                let result = try await tabManager.attachCmuxTUITerminal(
                    invitation: hasInvitation ? invitation : nil,
                    sessionID: sessionID,
                    publicTerminalID: publicTerminalID,
                    title: title,
                    focus: focus
                )
                let windowID = await MainActor.run {
                    AppDelegate.shared?.windowId(for: tabManager)
                }
                return .ok([
                    "session_id": result.sessionID.uuidString,
                    "window_id": windowID.map { $0.uuidString as Any } ?? NSNull(),
                    "workspace_id": result.workspaceID.uuidString,
                    "surface_id": result.panelID.uuidString,
                    "terminal_id": publicTerminalID,
                    "native": true,
                    "local_pty_created": false,
                ])
            } catch {
                return .err(
                    code: "tui_error",
                    message: error.localizedDescription,
                    data: nil
                )
            }
        }
    }

    nonisolated static func isValidCmuxTUIPublicTerminalID(_ value: String) -> Bool {
        guard value.hasPrefix("term_") else { return false }
        let payload = value.dropFirst(5)
        return payload.count == 32 && payload.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

internal import Foundation

/// The residual v1 line-protocol dispatch for the window commands
/// (`list_windows`, `current_window`, `focus_window`, `new_window`,
/// `close_window`, `move_workspace_to_window`) — the byte-faithful twins of the
/// former `TerminalController` v1 cases.
///
/// These commands have no exact v2 counterpart this coordinator could reshape:
/// the v1 commands take positional `<id>` arguments and return flat reply lines,
/// while the `window.*` methods take JSON params and return JSON. The v1
/// `current_window` / `focus_window` paths also differ behaviorally from their
/// v2 cousins (they read the controller's active `TabManager` directly and run
/// the `setActiveTabManager` side effect), so they cannot route through the
/// existing window resolutions. `list_windows` is the lone in-coordinator
/// formatter — its data source, ``ControlWindowContext/controlWindowSummaries()``,
/// is the same summary the `window.list` payload reads, so the flat-line
/// rendering is pure and drains here; the mutating bodies stay app-resident
/// behind the ``ControlWindowContext`` `*V1` witnesses and return their raw reply
/// line verbatim (the ``handleSurfaceSendNotifyV1`` shape).
extension ControlCommandCoordinator {
    /// Dispatches the v1 window commands this coordinator owns; returns `nil` for
    /// anything else so the app's legacy v1 dispatcher can fall through.
    ///
    /// - Parameters:
    ///   - command: The lowercased v1 command token.
    ///   - args: The raw argument remainder of the command line.
    /// - Returns: The raw reply line, or `nil` if not owned here.
    public func handleWindowV1(command: String, args: String) -> String? {
        switch command {
        case "list_windows":
            return listWindowsV1()
        case "current_window":
            return windowContext?.controlCurrentWindowV1()
                ?? Self.windowWorkspaceContextUnavailableResponse
        case "focus_window":
            return windowContext?.controlFocusWindowV1(arg: args)
                ?? Self.windowWorkspaceContextUnavailableResponse
        case "new_window":
            return windowContext?.controlNewWindowV1()
                ?? Self.windowWorkspaceContextUnavailableResponse
        case "close_window":
            return windowContext?.controlCloseWindowV1(arg: args)
                ?? Self.windowWorkspaceContextUnavailableResponse
        case "move_workspace_to_window":
            return windowContext?.controlMoveWorkspaceToWindowV1(args: args)
                ?? Self.windowWorkspaceContextUnavailableResponse
        default:
            return nil
        }
    }

    /// The window-domain slice of the seam (a typed view of ``context``).
    var windowContext: (any ControlWindowContext)? {
        context
    }

    /// The v1 `list_windows` body: renders one flat line per main window, in
    /// order, marking the key window with `*`. Pure formatting over the
    /// ``ControlWindowSummary`` snapshots (no app-coupled state beyond the
    /// summaries the seam already exposes), so it lives in the coordinator.
    ///
    /// - Returns: `"No windows"` when empty, else the newline-joined lines.
    func listWindowsV1() -> String {
        let summaries = windowContext?.controlWindowSummaries() ?? []
        guard !summaries.isEmpty else { return "No windows" }

        let lines = summaries.enumerated().map { idx, item in
            let selected = item.isKeyWindow ? "*" : " "
            let selectedWs = item.selectedWorkspaceID?.uuidString ?? "none"
            return "\(selected) \(idx): \(item.windowID.uuidString) selected_workspace=\(selectedWs) workspaces=\(item.workspaceCount)"
        }
        return lines.joined(separator: "\n")
    }

    /// The reply returned when the control context is not wired (unreachable in
    /// practice — the composition owner wires it during init). Matches the
    /// ``handleSurfaceSendNotifyV1`` unavailable-response shape.
    static let windowWorkspaceContextUnavailableResponse = "ERROR: control context unavailable"
}

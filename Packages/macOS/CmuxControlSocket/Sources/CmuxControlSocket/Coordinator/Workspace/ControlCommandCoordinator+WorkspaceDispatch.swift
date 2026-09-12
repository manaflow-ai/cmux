extension ControlCommandCoordinator {
    /// Dispatches the non-group workspace methods this coordinator owns; returns
    /// `nil` for anything else so the core `handle(_:)` can fall through.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not an owned workspace method.
    func handleWorkspace(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "workspace.list":
            // Worker-lane resolution read (tranche D): the nonisolated body is
            // shared with the socket dispatcher's worker lane; from this
            // main-actor dispatch its hop collapses inline.
            return workspaceList(request.params, context: context)
        case "workspace.create":
            return workspaceCreate(request.params)
        case "workspace.select":
            return workspaceSelect(request.params)
        case "workspace.current":
            return workspaceCurrent(request.params, context: context)
        case "workspace.font_size":
            return workspaceFontSize(request.params)
        case "workspace.close":
            return workspaceClose(request.params)
        case "workspace.move_to_window":
            return workspaceMoveToWindow(request.params)
        case "workspace.reorder":
            return workspaceReorder(request.params)
        case "workspace.reorder_many":
            return workspaceReorderMany(request.params)
        case "workspace.prompt_submit":
            return workspacePromptSubmit(request.params)
        case "workspace.rename":
            return workspaceRename(request.params)
        case "workspace.next":
            return workspaceNext(request.params)
        case "workspace.previous":
            return workspacePrevious(request.params)
        case "workspace.last":
            return workspaceLast(request.params)
        case "workspace.equalize_splits":
            return workspaceEqualizeSplits(request.params)
        case "workspace.remote.configure":
            return workspaceRemoteConfigure(request.params)
        case "workspace.remote.foreground_auth_ready":
            return workspaceRemoteForegroundAuthReady(request.params)
        case "workspace.remote.reconnect":
            return workspaceRemoteReconnect(request.params)
        case "workspace.remote.disconnect":
            return workspaceRemoteDisconnect(request.params)
        case "workspace.remote.status":
            return workspaceRemoteStatus(request.params)
        case "workspace.remote.pty_attach_end":
            return workspaceRemotePTYAttachEnd(request.params)
        case "workspace.remote.terminal_session_end":
            return workspaceRemoteTerminalSessionEnd(request.params)
        default:
            return nil
        }
    }
}

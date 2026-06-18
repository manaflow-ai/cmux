internal import Foundation

/// Shared rendering for terminal split/create requests aimed at a remote tmux
/// mirror workspace (used by `surface.split`, `surface.create`, and
/// `pane.create`).
extension ControlCommandCoordinator {
    /// Success payload for a request that was routed to the remote tmux mirror:
    /// the new pane/tab arrives asynchronously via the mirror's topology events
    /// (`%layout-change` / `%window-add`), so there is no local surface id to
    /// return yet. Returning an error here instead would make automation retry
    /// and duplicate remote panes — the remote session was already mutated.
    func remoteRoutedCreationResult(
        windowID: UUID?,
        workspaceID: UUID,
        typeRawValue: String
    ) -> ControlCallResult {
        .ok(.object([
            "accepted": .bool(true),
            "routed": .string("remote-tmux"),
            "window_id": orNull(windowID?.uuidString),
            "window_ref": ref(.window, windowID),
            "workspace_id": .string(workspaceID.uuidString),
            "workspace_ref": ref(.workspace, workspaceID),
            "pane_id": .null,
            "pane_ref": .null,
            "surface_id": .null,
            "surface_ref": .null,
            "type": .string(typeRawValue),
        ]))
    }

    /// `invalid_params` for options the routed tmux command cannot honor.
    /// The app rejects these BEFORE the remote session is mutated, so an error
    /// from this path always means "nothing happened" — safe to retry without
    /// the offending options.
    func mirrorUnsupportedOptionsResult(_ unsupported: [String]) -> ControlCallResult {
        .err(
            code: "invalid_params",
            message: "Not supported when targeting a remote tmux mirror workspace (the request is routed to tmux and these options cannot be applied): \(unsupported.joined(separator: ", "))",
            data: .object([
                "unsupported": .array(unsupported.map { .string($0) }),
                "routed_target": .string("remote-tmux"),
            ])
        )
    }
}

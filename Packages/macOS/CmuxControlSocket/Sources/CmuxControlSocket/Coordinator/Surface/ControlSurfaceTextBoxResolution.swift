public import Foundation

/// What a `surface.textbox.*` request asks of a terminal's TextBox Input.
public enum ControlSurfaceTextBoxAction: String, Sendable, Equatable, CaseIterable {
    /// Show the TextBox when hidden, hide it when shown (`surface.textbox.toggle`).
    case toggle
    /// Show the TextBox; a no-op when it is already shown (`surface.textbox.show`).
    case show
    /// Hide the TextBox; a no-op when it is already hidden (`surface.textbox.hide`).
    case hide
    /// Report whether the TextBox is shown without changing it
    /// (`surface.textbox.state`).
    case state

    /// The action a `surface.textbox.<action>` method names, or `nil` for any
    /// other method.
    ///
    /// - Parameter method: The trimmed v2 method name.
    public init?(method: String) {
        let prefix = "surface.textbox."
        guard method.hasPrefix(prefix) else { return nil }
        self.init(rawValue: String(method.dropFirst(prefix.count)))
    }

    /// The v2 method that requests this action.
    public var method: String { "surface.textbox.\(rawValue)" }
}

/// The outcome of a `surface.textbox.*` request.
///
/// The coordinator signals `unavailable`; the app resolves the workspace and the
/// terminal surface, applies the action, and returns this resolution.
public enum ControlSurfaceTextBoxResolution: Sendable, Equatable {
    /// No TabManager resolved (`unavailable` / "TabManager not available").
    case tabManagerUnavailable
    /// No workspace resolved (`not_found` / "Workspace not found").
    case workspaceNotFound
    /// The requested Dock cannot be revealed for explicit TextBox focus.
    case dockUnavailable(message: String)
    /// A `surface_id` param was present but did not resolve (`not_found` /
    /// "Surface not found for the given surface_id"). It never falls back to the
    /// focused surface.
    case surfaceNotFoundForID
    /// No surface was named and none is focused (`not_found` / "No focused
    /// surface").
    case noFocusedSurface
    /// The resolved surface is not a terminal (`invalid_params` / "Surface is not
    /// a terminal", `data: {"surface_id": …}`). Carries the surface id.
    case surfaceNotTerminal(UUID)
    /// The action ran. `visible` is the TextBox state afterwards and `changed`
    /// says whether the action changed it.
    case applied(windowID: UUID?, workspaceID: UUID, surfaceID: UUID, visible: Bool, changed: Bool)
}

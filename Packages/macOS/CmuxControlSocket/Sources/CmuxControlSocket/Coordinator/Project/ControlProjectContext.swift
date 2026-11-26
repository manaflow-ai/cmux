public import Foundation

/// The project/file-opening-domain slice of the control-command seam (a
/// constituent of the ``ControlCommandContext`` umbrella): `project.open`, the
/// `project.set_*` / `project.get_state` debug RPCs, plus the cohesive
/// file-into-panel openers `markdown.open` and `file.open`.
///
/// Every method is `@MainActor`: the conformer (the interim composition owner)
/// and the coordinator both live on the main actor, so these are plain
/// in-isolation calls.
@MainActor
public protocol ControlProjectContext: AnyObject {
    /// Whether the routing selectors resolve a TabManager (the legacy
    /// `v2ResolveTabManager != nil` precheck that precedes the path
    /// validation in `project.open` / `markdown.open` / `file.open`).
    ///
    /// - Parameter routing: The routing selectors.
    /// - Returns: Whether a TabManager resolved.
    func controlProjectRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool

    /// Opens a project panel for `project.open` (the path is already
    /// validated).
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - path: The resolved absolute project path.
    ///   - requestedFocus: The requested `focus` flag (the app applies the
    ///     focus-allowance policy).
    /// - Returns: The open resolution.
    func controlProjectOpen(
        routing: ControlRoutingSelectors,
        path: String,
        requestedFocus: Bool
    ) -> ControlProjectOpenResolution

    /// Sets the active project tab for `project.set_tab`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - surfaceID: The explicit `surface_id`, if any.
    ///   - tabRaw: The raw `tab` param, if any.
    /// - Returns: The set resolution.
    func controlProjectSetTab(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        tabRaw: String?
    ) -> ControlProjectSetTabResolution

    /// Sets the selected scheme for `project.set_scheme`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - surfaceID: The explicit `surface_id`, if any.
    ///   - name: The scheme name, if any.
    /// - Returns: The update resolution.
    func controlProjectSetScheme(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        name: String?
    ) -> ControlProjectUpdateResolution

    /// Sets the selected configuration for `project.set_configuration`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - surfaceID: The explicit `surface_id`, if any.
    ///   - name: The configuration name, if any.
    /// - Returns: The update resolution.
    func controlProjectSetConfiguration(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        name: String?
    ) -> ControlProjectUpdateResolution

    /// Sets the selected target for `project.set_selected_target`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - surfaceID: The explicit `surface_id`, if any.
    ///   - name: The target display name, if any.
    /// - Returns: The target resolution (carries the resolved target id).
    func controlProjectSetSelectedTarget(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        name: String?
    ) -> ControlProjectTargetResolution

    /// Sets the selected file for `project.set_selected_file`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - surfaceID: The explicit `surface_id`, if any.
    ///   - path: The file path, if any.
    /// - Returns: The update resolution.
    func controlProjectSetSelectedFile(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        path: String?
    ) -> ControlProjectUpdateResolution

    /// Sets the build-settings filter for `project.set_settings_filter`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - surfaceID: The explicit `surface_id`, if any.
    ///   - text: The filter text (`""` when absent).
    /// - Returns: The update resolution.
    func controlProjectSetSettingsFilter(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        text: String
    ) -> ControlProjectUpdateResolution

    /// Snapshots the project panel state for `project.get_state`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - surfaceID: The explicit `surface_id`, if any.
    /// - Returns: The state resolution.
    func controlProjectGetState(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> ControlProjectStateResolution

    /// Creates a markdown split for `markdown.open` (the path is already
    /// validated), running the legacy in-block order: workspace, focus side
    /// effects, source surface, direction, font-size validation, create.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - surfaceID: The explicit source `surface_id`, if any.
    ///   - filePath: The resolved readable file path.
    ///   - directionRaw: The raw direction token (default `"right"`).
    ///   - fontSize: The parsed `font_size`, if numeric (the app clamps it).
    ///   - fontSizeInvalid: Whether `font_size` was present but non-numeric.
    ///   - requestedFocus: The requested `focus` flag (the app applies the
    ///     focus-allowance policy).
    /// - Returns: The open resolution.
    func controlMarkdownOpen(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        filePath: String,
        directionRaw: String,
        fontSize: Double?,
        fontSizeInvalid: Bool,
        requestedFocus: Bool
    ) -> ControlMarkdownOpenResolution

    /// Opens file surfaces for `file.open` (the paths are already validated).
    ///
    /// Forwards to the shared `v2FileOpen` body (also driven by cmuxTests) and
    /// bridges its Foundation payload — a single source of truth.
    ///
    /// - Parameter params: The raw command params; the body parses them and
    ///   mints refs itself.
    /// - Returns: The bridged call result.
    func controlFileOpen(params: [String: JSONValue]) -> ControlCallResult
}

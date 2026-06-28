internal import Foundation

/// The `system.identify` payload shaping, lifted byte-faithfully from the
/// former `TerminalController.v2Identify`. The coordinator owns the
/// focused/caller payload-dict construction and the `kind:N` ref minting; the
/// live window/workspace/pane/surface graph reads come through
/// ``ControlIdentifyContext``.
///
/// This is the single identify entry: the `system.identify` dispatch, the
/// shared window-routing parse (``systemWindowRouting(_:)``), and the app-side
/// worker-lane `system.top` / `system.memory` base payload all resolve their
/// `focused` / `caller` identity here.
extension ControlCommandCoordinator {
    /// The identify-domain slice of the seam. A typed view of ``context`` so the
    /// domain compiles independently of the umbrella's inheritance list (the
    /// umbrella already refines ``ControlIdentifyContext``, so this is a plain
    /// existential upcast, not a runtime downcast).
    var identifyContext: (any ControlIdentifyContext)? {
        context
    }

    /// The fully-shaped `system.identify` payload (the legacy `v2Identify`): the
    /// `socket_path`, the `focused` location, an optional validated `caller`
    /// location, and the app-bundle path tail.
    ///
    /// - Parameter params: The identify params (`caller`, `window_id`, …).
    /// - Returns: The identify payload object (JSON `{}` only when no seam is
    ///   wired).
    public func identify(params: [String: JSONValue]) -> JSONValue {
        guard let identifyContext else { return .object([:]) }
        let socketPath = identifyContext.controlIdentifySocketPath()

        guard let focusedSnapshot = identifyContext.controlIdentifyFocused(params: params) else {
            return .object([
                "socket_path": .string(socketPath),
                "focused": .null,
                "caller": .null,
            ])
        }

        let focused = identifyFocusedPayload(focusedSnapshot)

        var resolvedCaller: [String: JSONValue]?
        if case .object(let callerObject)? = params["caller"],
           let workspaceID = uuidAny(callerObject["workspace_id"]) {
            let surfaceID = uuidAny(callerObject["surface_id"]) ?? uuidAny(callerObject["tab_id"])
            if let callerSnapshot = identifyContext.controlIdentifyCaller(
                params: params,
                workspaceID: workspaceID,
                surfaceID: surfaceID
            ) {
                resolvedCaller = identifyCallerPayload(callerSnapshot)
            }
        }

        var result: [String: JSONValue] = [
            "socket_path": .string(socketPath),
            "focused": focused.isEmpty ? .null : .object(focused),
            "caller": resolvedCaller.map { JSONValue.object($0) } ?? .null,
        ]

        let bundle = identifyContext.controlIdentifyBundle()
        if let bundleIdentifier = bundle.bundleIdentifier {
            result["bundle_identifier"] = .string(bundleIdentifier)
        }
        result["app_bundle_path"] = .string(bundle.bundlePath)
        if let executablePath = bundle.executablePath {
            result["app_executable_path"] = .string(executablePath)
        }
        if let cliPath = bundle.cliPath {
            result["app_cli_path"] = .string(cliPath)
        }
        return .object(result)
    }

    /// The `focused` location dict (the legacy `v2Identify` `focused` block).
    private func identifyFocusedPayload(_ snapshot: ControlIdentifyFocusedSnapshot) -> [String: JSONValue] {
        guard let selected = snapshot.selected else {
            return [
                "window_id": orNull(snapshot.windowID?.uuidString),
                "window_ref": ref(.window, snapshot.windowID),
            ]
        }
        return [
            "window_id": orNull(snapshot.windowID?.uuidString),
            "window_ref": ref(.window, snapshot.windowID),
            "workspace_id": .string(selected.workspaceID.uuidString),
            "workspace_ref": ref(.workspace, selected.workspaceID),
            "pane_id": orNull(selected.paneID?.uuidString),
            "pane_ref": ref(.pane, selected.paneID),
            "surface_id": orNull(selected.surfaceID?.uuidString),
            "surface_ref": ref(.surface, selected.surfaceID),
            "tab_id": orNull(selected.surfaceID?.uuidString),
            "tab_ref": tabRef(selected.surfaceID),
            "surface_type": orNull(selected.surfaceTypeRawValue),
            "is_browser_surface": selected.isBrowserSurface.map { JSONValue.bool($0) } ?? .null,
        ]
    }

    /// The validated `caller` location dict (the legacy `v2Identify` `caller`
    /// block), emitting all-null surface fields when no valid surface resolved.
    private func identifyCallerPayload(_ snapshot: ControlIdentifyCallerSnapshot) -> [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "window_id": orNull(snapshot.windowID?.uuidString),
            "window_ref": ref(.window, snapshot.windowID),
            "workspace_id": .string(snapshot.workspaceID.uuidString),
            "workspace_ref": ref(.workspace, snapshot.workspaceID),
        ]

        if let surface = snapshot.surface {
            payload["surface_id"] = .string(surface.surfaceID.uuidString)
            payload["surface_ref"] = ref(.surface, surface.surfaceID)
            payload["tab_id"] = .string(surface.surfaceID.uuidString)
            payload["tab_ref"] = tabRef(surface.surfaceID)
            payload["surface_type"] = orNull(surface.surfaceTypeRawValue)
            payload["is_browser_surface"] = surface.isBrowserSurface.map { JSONValue.bool($0) } ?? .null
            payload["pane_id"] = orNull(surface.paneID?.uuidString)
            payload["pane_ref"] = ref(.pane, surface.paneID)
        } else {
            payload["surface_id"] = .null
            payload["surface_ref"] = .null
            payload["tab_id"] = .null
            payload["tab_ref"] = .null
            payload["surface_type"] = .null
            payload["is_browser_surface"] = .null
            payload["pane_id"] = .null
            payload["pane_ref"] = .null
        }
        return payload
    }
}

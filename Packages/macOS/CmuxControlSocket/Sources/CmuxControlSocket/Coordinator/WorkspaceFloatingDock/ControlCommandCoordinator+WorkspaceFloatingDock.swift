internal import Foundation

extension ControlCommandCoordinator {
    nonisolated private static let maximumFloatingDockNoteBytes = 16 * 1024 * 1024

    func handleWorkspaceFloatingDock(_ request: ControlRequest) -> ControlCallResult? {
        let workspaceID = uuid(request.params, "workspace_id")
        if hasNonNull(request.params, "workspace_id"), workspaceID == nil {
            return invalidFloatingDockIdentifier("workspace_id")
        }
        let action: ControlWorkspaceFloatingDockAction
        switch request.method {
        case "workspace.float.list":
            action = .list
        case "workspace.float.create":
            let frame = floatingDockFrame(request.params, required: false)
            if let error = frame.error { return error }
            action = .create(
                title: optionalTrimmedRawString(request.params, "title"),
                frame: frame.value,
                kind: string(request.params, "kind") ?? "terminal",
                url: optionalTrimmedRawString(request.params, "url"),
                backgroundTintHex: optionalTrimmedRawString(request.params, "color"),
                relativeToSelector: optionalTrimmedRawString(request.params, "relative_to"),
                focus: bool(request.params, "focus") ?? false
            )
        case "workspace.float.show", "workspace.float.hide":
            guard let selector = floatingDockSelector(request.params) else { return missingFloatingDock() }
            action = .setPresented(
                selector: selector,
                presented: request.method == "workspace.float.show",
                focus: bool(request.params, "focus") ?? false
            )
        case "workspace.float.focus":
            guard let selector = floatingDockSelector(request.params) else { return missingFloatingDock() }
            action = .focus(selector: selector)
        case "workspace.float.close":
            guard let selector = floatingDockSelector(request.params) else { return missingFloatingDock() }
            action = .close(selector: selector)
        case "workspace.float.close_all":
            action = .closeAll
        case "workspace.float.set_frame":
            guard let selector = floatingDockSelector(request.params) else { return missingFloatingDock() }
            let frame = floatingDockFrame(request.params, required: true)
            if let error = frame.error { return error }
            guard let value = frame.value else {
                return .err(code: "invalid_params", message: "x, y, width, and height are required", data: nil)
            }
            action = .setFrame(selector: selector, frame: value)
        case "workspace.float.color.get":
            guard let selector = floatingDockSelector(request.params) else { return missingFloatingDock() }
            action = .colorGet(selector: selector)
        case "workspace.float.color.set", "workspace.float.color.reset":
            guard let selector = floatingDockSelector(request.params) else { return missingFloatingDock() }
            action = .colorSet(
                selector: selector,
                backgroundTintHex: request.method == "workspace.float.color.reset"
                    ? nil
                    : optionalTrimmedRawString(request.params, "color")
            )
        case "workspace.float.note.get":
            guard let selector = floatingDockSelector(request.params) else { return missingFloatingDock() }
            action = .noteGet(selector: selector)
        case "workspace.float.note.set":
            guard let selector = floatingDockSelector(request.params) else { return missingFloatingDock() }
            guard let text = rawString(request.params, "text") else {
                return .err(code: "invalid_params", message: "Missing or invalid text", data: nil)
            }
            action = .noteSet(selector: selector, text: text)
        case "workspace.float.surface.create":
            guard let selector = floatingDockSelector(request.params) else { return missingFloatingDock() }
            guard let kind = string(request.params, "kind") else {
                return .err(code: "invalid_params", message: "Missing or invalid kind", data: nil)
            }
            let paneID = uuid(request.params, "pane_id")
            if hasNonNull(request.params, "pane_id"), paneID == nil {
                return invalidFloatingDockIdentifier("pane_id")
            }
            action = .surfaceCreate(
                selector: selector,
                paneID: paneID,
                kind: kind,
                url: optionalTrimmedRawString(request.params, "url"),
                focus: bool(request.params, "focus") ?? false
            )
        case "workspace.float.pane.create":
            guard let selector = floatingDockSelector(request.params) else { return missingFloatingDock() }
            guard let kind = string(request.params, "kind") else {
                return .err(code: "invalid_params", message: "Missing or invalid kind", data: nil)
            }
            let sourceSurfaceID = uuid(request.params, "surface_id")
            if hasNonNull(request.params, "surface_id"), sourceSurfaceID == nil {
                return invalidFloatingDockIdentifier("surface_id")
            }
            action = .paneCreate(
                selector: selector,
                sourceSurfaceID: sourceSurfaceID,
                kind: kind,
                direction: string(request.params, "direction") ?? "right",
                url: optionalTrimmedRawString(request.params, "url"),
                focus: bool(request.params, "focus") ?? false
            )
        default:
            return nil
        }

        let resolution = context?.controlWorkspaceFloatingDock(
            routing: routingSelectors(request.params),
            workspaceID: workspaceID,
            action: action
        ) ?? .tabManagerUnavailable
        return floatingDockResult(resolution)
    }

    nonisolated func workspaceFloatingDockNoteSet(
        _ params: [String: JSONValue],
        context: (any ControlCommandContext)?
    ) -> ControlCallResult {
        guard let context else {
            return .err(code: "unavailable", message: "Workspace controls are unavailable", data: nil)
        }
        let parsed: FloatingDockNoteSetParse = context.controlResolveOnMain { _ in
            let workspaceID = self.uuid(params, "workspace_id")
            if self.hasNonNull(params, "workspace_id"), workspaceID == nil {
                return .invalidWorkspaceID
            }
            guard let selector = self.floatingDockSelector(params) else {
                return .missingSelector
            }
            guard case .string(let text)? = params["text"] else {
                return .missingText
            }
            return .ready(
                routing: self.routingSelectors(params),
                workspaceID: workspaceID,
                selector: selector,
                text: text
            )
        }
        switch parsed {
        case .invalidWorkspaceID:
            return invalidFloatingDockIdentifier("workspace_id")
        case .missingSelector:
            return missingFloatingDock()
        case .missingText:
            return .err(code: "invalid_params", message: "Missing or invalid text", data: nil)
        case let .ready(routing, workspaceID, selector, text):
            guard text.utf8.count <= Self.maximumFloatingDockNoteBytes else {
                return .err(
                    code: "invalid_params",
                    message: "Floating Dock note exceeds the 16 MiB limit",
                    data: .object(["maximum_bytes": .int(Int64(Self.maximumFloatingDockNoteBytes))])
                )
            }
            return floatingDockResult(context.controlSetWorkspaceFloatingDockNote(
                routing: routing,
                workspaceID: workspaceID,
                selector: selector,
                text: text
            ))
        }
    }

    private enum FloatingDockNoteSetParse: Sendable {
        case invalidWorkspaceID
        case missingSelector
        case missingText
        case ready(
            routing: ControlRoutingSelectors,
            workspaceID: UUID?,
            selector: String,
            text: String
        )
    }

    private func floatingDockSelector(_ params: [String: JSONValue]) -> String? {
        string(params, "float") ?? string(params, "float_id")
    }

    private func floatingDockFrame(
        _ params: [String: JSONValue],
        required: Bool
    ) -> (value: ControlWorkspaceFloatingDockAction.Frame?, error: ControlCallResult?) {
        let keys = ["x", "y", "width", "height"]
        let hasAny = keys.contains { hasNonNull(params, $0) }
        guard required || hasAny else { return (nil, nil) }
        guard let x = double(params, "x"), x.isFinite,
              let y = double(params, "y"), y.isFinite,
              let width = double(params, "width"), width.isFinite, width > 0,
              let height = double(params, "height"), height.isFinite, height > 0 else {
            return (nil, .err(
                code: "invalid_params",
                message: "x, y, width, and height must be finite numbers",
                data: nil
            ))
        }
        return (.init(x: x, y: y, width: width, height: height), nil)
    }

    nonisolated private func missingFloatingDock() -> ControlCallResult {
        .err(code: "invalid_params", message: "Missing floating Dock selector", data: nil)
    }

    nonisolated private func invalidFloatingDockIdentifier(_ key: String) -> ControlCallResult {
        .err(code: "invalid_params", message: "\(key) must be a UUID", data: nil)
    }

    nonisolated private func floatingDockResult(
        _ resolution: ControlWorkspaceFloatingDockResolution
    ) -> ControlCallResult {
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "Workspace controls are unavailable", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .floatingDockNotFound:
            return .err(code: "not_found", message: "Floating Dock not found", data: nil)
        case .paneNotFound:
            return .err(code: "not_found", message: "Floating Dock pane not found", data: nil)
        case .surfaceNotFound:
            return .err(code: "not_found", message: "Floating Dock surface not found", data: nil)
        case .invalidInitialContent(let kind):
            return .err(
                code: "invalid_params",
                message: "kind must be terminal, browser, or notes",
                data: .object(["kind": .string(kind)])
            )
        case .invalidSurfaceKind(let kind):
            return .err(
                code: "invalid_params",
                message: "kind must be terminal or browser",
                data: .object(["kind": .string(kind)])
            )
        case .invalidDirection(let direction):
            return .err(
                code: "invalid_params",
                message: "direction must be left, right, up, or down",
                data: .object(["direction": .string(direction)])
            )
        case .invalidColor(let color):
            return .err(
                code: "invalid_params",
                message: "color must use #RRGGBB format",
                data: .object(["color": .string(color)])
            )
        case .operationFailed:
            return .err(code: "internal_error", message: "The floating Dock operation failed", data: nil)
        case .resolved(let payload):
            return .ok(payload)
        }
    }
}

internal import Foundation

extension ControlCommandCoordinator {
    func surfaceOverlaySet(_ params: [String: JSONValue]) -> ControlCallResult {
        let id = rawString(params, "overlay_id") ?? ""
        let text = rawString(params, "text") ?? ""
        let rawAnchor = optionalTrimmedRawString(params, "anchor") ?? "viewport"
        let anchor: ControlSurfaceOverlayAnchor
        switch rawAnchor.lowercased() {
        case "viewport", "viewport-top":
            anchor = .viewportTop
        case "scrollback", "scrollback-top":
            anchor = .scrollbackTop
        case "sticky", "scrollback-sticky":
            anchor = .scrollbackSticky
        default:
            return overlayValidationError(.invalidAnchor(rawAnchor))
        }

        let rawAlignment = optionalTrimmedRawString(params, "position") ?? "center"
        guard let alignment = ControlSurfaceOverlayAlignment(rawValue: rawAlignment.lowercased()) else {
            return overlayValidationError(.invalidAlignment(rawAlignment))
        }
        return surfaceOverlay(
            params,
            action: .set(ControlSurfaceOverlaySetInputs(
                id: id,
                text: text,
                anchor: anchor,
                alignment: alignment
            ))
        )
    }

    func surfaceOverlayRemove(_ params: [String: JSONValue]) -> ControlCallResult {
        surfaceOverlay(
            params,
            action: .remove(id: rawString(params, "overlay_id") ?? "")
        )
    }

    func surfaceOverlay(
        _ params: [String: JSONValue],
        action: ControlSurfaceOverlayAction
    ) -> ControlCallResult {
        let routing = routingSelectors(params)
        let resolution = context?.controlSurfaceOverlay(
            routing: routing,
            surfaceID: uuid(params, "surface_id"),
            hasSurfaceIDParam: params["surface_id"] != nil,
            action: action
        ) ?? .tabManagerUnavailable
        return surfaceOverlayResult(resolution)
    }

    private func surfaceOverlayResult(
        _ resolution: ControlSurfaceOverlayResolution
    ) -> ControlCallResult {
        let strings = overlayStrings()
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: strings.tabManagerUnavailable, data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: strings.workspaceNotFound, data: nil)
        case .surfaceNotFound:
            return .err(code: "not_found", message: strings.surfaceNotFound, data: nil)
        case .noFocusedSurface:
            return .err(code: "not_found", message: strings.noFocusedSurface, data: nil)
        case .surfaceNotTerminal(let surfaceID):
            return .err(
                code: "invalid_params",
                message: strings.surfaceNotTerminal,
                data: .object(["surface_id": .string(surfaceID.uuidString)])
            )
        case .validationFailed(let error):
            return overlayValidationError(error)
        case .scrollbackUnavailable(let surfaceID):
            return .err(
                code: "unavailable",
                message: strings.scrollbackUnavailable,
                data: .object(["surface_id": .string(surfaceID.uuidString)])
            )
        case .listed(let windowID, let workspaceID, let surfaceID, let overlays):
            var payload = surfaceOverlayTargetPayload(
                windowID: windowID,
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
            payload["overlays"] = .array(overlays.map(surfaceOverlayPayload))
            return .ok(.object(payload))
        case .set(let windowID, let workspaceID, let surfaceID, let overlay):
            var payload = surfaceOverlayTargetPayload(
                windowID: windowID,
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
            payload["overlay"] = surfaceOverlayPayload(overlay)
            return .ok(.object(payload))
        case .removed(let windowID, let workspaceID, let surfaceID, let overlayID, let removed):
            var payload = surfaceOverlayTargetPayload(
                windowID: windowID,
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
            payload["overlay_id"] = .string(overlayID)
            payload["removed"] = .bool(removed)
            return .ok(.object(payload))
        case .cleared(let windowID, let workspaceID, let surfaceID, let removedCount):
            var payload = surfaceOverlayTargetPayload(
                windowID: windowID,
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
            payload["removed"] = .int(Int64(removedCount))
            return .ok(.object(payload))
        }
    }

    private func overlayValidationError(
        _ error: ControlSurfaceOverlayValidationError
    ) -> ControlCallResult {
        let strings = overlayStrings()
        let message: String
        switch error {
        case .invalidIdentifier:
            message = strings.invalidIdentifier
        case .emptyText:
            message = strings.emptyText
        case .textTooLong(let maxUTF8Bytes):
            message = String.localizedStringWithFormat(
                strings.textTooLongFormat,
                Int64(maxUTF8Bytes)
            )
        case .invalidAnchor(let value):
            message = String.localizedStringWithFormat(strings.invalidAnchorFormat, value)
        case .invalidAlignment(let value):
            message = String.localizedStringWithFormat(strings.invalidAlignmentFormat, value)
        }
        return .err(code: "invalid_params", message: message, data: nil)
    }

    private func overlayStrings() -> ControlSurfaceOverlayStrings {
        context?.controlSurfaceOverlayStrings() ?? ControlSurfaceOverlayStrings(
            tabManagerUnavailable: "",
            workspaceNotFound: "",
            surfaceNotFound: "",
            noFocusedSurface: "",
            surfaceNotTerminal: "",
            invalidIdentifier: "",
            emptyText: "",
            textTooLongFormat: "",
            invalidAnchorFormat: "",
            invalidAlignmentFormat: "",
            scrollbackUnavailable: ""
        )
    }

    private func surfaceOverlayTargetPayload(
        windowID: UUID?,
        workspaceID: UUID,
        surfaceID: UUID
    ) -> [String: JSONValue] {
        [
            "window_id": orNull(windowID?.uuidString),
            "window_ref": ref(.window, windowID),
            "workspace_id": .string(workspaceID.uuidString),
            "workspace_ref": ref(.workspace, workspaceID),
            "surface_id": .string(surfaceID.uuidString),
            "surface_ref": ref(.surface, surfaceID),
        ]
    }

    private func surfaceOverlayPayload(_ overlay: ControlSurfaceOverlaySnapshot) -> JSONValue {
        let anchor = switch overlay.anchor {
        case .viewportTop: "viewport"
        case .scrollbackTop: "scrollback"
        case .scrollbackSticky: "sticky"
        }
        return .object([
            "id": .string(overlay.id),
            "text": .string(overlay.text),
            "anchor": .string(anchor),
            "position": .string(overlay.alignment.rawValue),
            "scrollback_row": overlay.scrollbackRow.map { .int(Int64($0)) } ?? .null,
            "row_space_revision": overlay.rowSpaceRevision.map { .int(Int64(clamping: $0)) } ?? .null,
        ])
    }
}

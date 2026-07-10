internal import Foundation

extension ControlCommandCoordinator {
    /// `surface.pip` — pop out / return / toggle a surface picture-in-picture panel.
    func surfacePip(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let context else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let action = string(params, "action") ?? "toggle"
        guard ["pop", "return", "toggle"].contains(action) else {
            return .err(
                code: "invalid_params",
                message: #"action must be "pop", "return", or "toggle""#,
                data: .object(["action": .string(action)])
            )
        }
        let hasSurfaceIDParam = params["surface_id"] != nil
        let surfaceID = uuid(params, "surface_id")
        if hasSurfaceIDParam, surfaceID == nil {
            return .err(code: "invalid_params", message: "Invalid surface_id", data: nil)
        }

        let resolution = context.controlSurfacePip(
            routing: routingSelectors(params),
            surfaceID: surfaceID,
            actionRawValue: action
        )
        switch resolution {
        case .changed(let surfaceID, let isInPictureInPicture):
            return .ok(.object([
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "in_picture_in_picture": .bool(isInPictureInPicture),
                "action": .string(action),
            ]))
        case .surfaceNotFound:
            return .err(code: "not_found", message: "Surface not found", data: nil)
        case .unsupportedSurfaceType:
            return .err(
                code: "invalid_params",
                message: "Picture in Picture supports only terminal and browser surfaces",
                data: nil
            )
        case .notInPictureInPicture:
            return .err(code: "invalid_state", message: "Surface is not in Picture in Picture", data: nil)
        case .failed:
            return .err(code: "failed", message: "Failed to update Picture in Picture state", data: nil)
        }
    }
}

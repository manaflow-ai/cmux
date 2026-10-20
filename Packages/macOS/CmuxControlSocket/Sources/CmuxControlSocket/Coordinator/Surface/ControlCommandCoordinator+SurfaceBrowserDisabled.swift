internal import Foundation

extension ControlCommandCoordinator {
    /// The shared `surface.split` / `surface.create` browser-disabled external-open
    /// result (byte-faithful twin of `v2BrowserDisabledExternalOpenResult`).
    func browserDisabledResult(_ outcome: ControlSurfaceBrowserDisabledOutcome) -> ControlCallResult {
        switch outcome {
        case .invalidURL(let rawURL):
            return .err(code: "invalid_params", message: "Invalid URL", data: .object(["url": .string(rawURL)]))
        case .noURL:
            return .err(code: "browser_disabled", message: "cmux browser is disabled", data: nil)
        case .externalOpenFailed(let url):
            return .err(
                code: "external_open_failed",
                message: "Failed to open URL externally",
                data: .object(["url": .string(url)])
            )
        case .openedExternally(let windowID, let url):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .null,
                "workspace_ref": .null,
                "pane_id": .null,
                "pane_ref": .null,
                "surface_id": .null,
                "surface_ref": .null,
                "created_split": .bool(false),
                "opened_externally": .bool(true),
                "browser_disabled": .bool(true),
                "placement_strategy": .string("external_browser_disabled"),
                "url": .string(url),
            ]))
        }
    }
}

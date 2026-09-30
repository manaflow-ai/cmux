import AppKit
import GhosttyKit

/// Routes decoded actions on the main actor.
enum GhosttyActionDispatcher {
    static func dispatch(_ action: GhosttyAction, bridge: SurfaceBridge?, runtime: GhosttyRuntime?) -> Bool {
        switch action {
        case .configChange(let pointer):
            // Surface-targeted config changes are per-surface overrides the
            // renderer already applied; only the app-level one is adopted.
            guard let config = pointer.raw else { return true }
            if bridge == nil, let runtime {
                runtime.adoptAppliedConfig(config)
            } else {
                ghostty_config_free(config)
            }
            return true
        case .reloadConfig(let soft):
            guard let runtime else { return false }
            if soft, let app = runtime.app, let config = runtime.config {
                ghostty_app_update_config(app, config)
                // Surfaces with their own theme take it back.
                runtime.onConfigChange?()
            } else {
                runtime.reloadConfig()
            }
            return true
        case .openConfig:
            let path = ghostty_config_open_path()
            defer { ghostty_string_free(path) }
            guard let pointer = path.ptr, path.len > 0 else { return false }
            let text = String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(path.len)), as: UTF8.self)
            NSWorkspace.shared.open(URL(fileURLWithPath: text))
            return true
        case .host(let hostAction):
            if let view = bridge?.view {
                return view.handleHostAction(hostAction)
            }
            return runtime?.appActionHandler?(hostAction) ?? false
        default:
            guard let view = bridge?.view else { return false }
            return view.applyAction(action)
        }
    }
}

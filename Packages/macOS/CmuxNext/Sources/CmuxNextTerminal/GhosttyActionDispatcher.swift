import AppKit
import GhosttyNextKit
import CmuxNextCompat

/// Routes decoded actions on the main actor.
enum GhosttyActionDispatcher {
    static func dispatch(_ action: GhosttyAction, bridge: SurfaceBridge?, runtime: GhosttyRuntime?) -> Bool {
        switch action {
        case .configChange(let pointer):
            // Surface-targeted config changes are per-surface overrides the
            // renderer already applied; only the app-level one is adopted.
            // SAFETY: the decoder's clone of the applied config (GhosttyActionDecoder), owned by
            // this action and used once: adopted (cloned again) or freed, never both.
            guard let config = unsafe pointer.raw else { return true }
            if bridge == nil, let runtime {
                // SAFETY: as above.
                unsafe runtime.adoptAppliedConfig(config)
            }
            // SAFETY: as above; adoption keeps its own clone, so this one is freed either way.
            unsafe ghostty_config_free(config)
            return true
        case .reloadConfig(let soft):
            guard let runtime else { return false }
            if soft, let app = runtime.app, let config = runtime.config {
                runtime.applyColorTransitionToSurfaces()
                // SAFETY: the runtime's live app and applied config (GhosttyRuntime's notes);
                // update_config copies what it keeps.
                unsafe ghostty_app_update_config(app, config)
                // Surfaces with their own theme take it back.
                runtime.onConfigChange?()
            } else {
                runtime.reloadConfig()
            }
            return true
        case .openConfig:
            // SAFETY: open_path returns a string of `len` bytes that this case owns and frees
            // once (defer); the text is copied before the free.
            let path = unsafe ghostty_config_open_path()
            // SAFETY: as above.
            defer { unsafe ghostty_string_free(path) }
            // SAFETY: as above.
            guard let pointer = unsafe path.ptr, path.len > 0 else { return false }
            // SAFETY: as above.
            let text = unsafe String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(path.len)), as: UTF8.self)
            NSWorkspace.shared.openInBackground(URL(fileURLWithPath: text))
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

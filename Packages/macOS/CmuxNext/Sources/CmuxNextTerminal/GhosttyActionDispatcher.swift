import AppKit
import GhosttyNextKit
import CmuxNextCompatAppKit

/// Routes decoded actions on the main actor.
enum GhosttyActionDispatcher {
    /// Gives back the decoder's clone of an applied config (`.configChange`) once the action is done with
    /// it: ``freeConfig(_:)`` in the app, a counter in a test.
    typealias ConfigRelease = (UncheckedPointer) -> Void

    static func dispatch(_ action: GhosttyAction, bridge: SurfaceBridge?, runtime: GhosttyRuntime?,
                         releaseConfig: ConfigRelease = GhosttyActionDispatcher.freeConfig) -> Bool {
        switch action {
        case .configChange(let pointer):
            // Surface-targeted config changes are per-surface overrides the
            // renderer already applied; only the app-level one is adopted.
            // SAFETY: the decoder's clone of the applied config (GhosttyActionDecoder), owned by
            // this action until `releaseConfig` takes it back.
            guard let config = unsafe pointer.raw else { return true }
            if bridge == nil, let runtime {
                // SAFETY: as above.
                unsafe runtime.adoptAppliedConfig(config)
            }
            // Adoption keeps a clone of its own, so this one is given back on every path.
            releaseConfig(pointer)
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
            if let target = bridge?.target {
                return target.handleHostAction(hostAction)
            }
            return runtime?.appActionHandler?(hostAction) ?? false
        default:
            guard let target = bridge?.target else { return false }
            return target.applyAction(action)
        }
    }

    /// The app's ``ConfigRelease``: the one free of the decoder's clone.
    nonisolated static func freeConfig(_ handle: UncheckedPointer) {
        // SAFETY: `handle` is the decoder's clone, which only `dispatch` gives back, once per action.
        unsafe ghostty_config_free(handle.raw)
    }
}

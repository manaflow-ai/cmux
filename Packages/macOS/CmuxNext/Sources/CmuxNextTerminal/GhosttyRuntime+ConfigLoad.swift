import GhosttyNextKit

/// Config loads: each build runs on the loader (``GhosttyConfigLoading``, the app's files lane) and its result is
/// applied on the main actor once, in one `ghostty_app_update_config`. No `ghostty_config_load_*` runs on the main
/// actor.
extension GhosttyRuntime {
    /// Builds the first config on `loader` with the overrides set now (cmux.json's appearance, primed), keeps
    /// `loader` for every later build, starts libghostty's app with the config when it lands on the main actor, then
    /// runs `then`. The main thread does other work meanwhile.
    public func start(loadingOn loader: any GhosttyConfigLoading, then: @escaping @MainActor @Sendable () -> Void) {
        configLoader = loader
        let inputs = configInputs(theme: nil)
        loader.load({ inputs.buildConfig() }) { [weak self] built in
            guard let self else {
                built?.free()
                return then()
            }
            self.start(with: built)
            // Overrides that changed while the first build ran (its snapshot predates them).
            if self.reloadAfterStart {
                self.reloadAfterStart = false
                self.reloadConfig()
            }
            then()
        }
    }

    /// Reloads the user's Ghostty config on the loader and, when it lands on the main actor, pushes it to every
    /// surface (`ghostty_app_update_config`, ghostty.h:1339). A later request supersedes one still in flight; one
    /// asked before the first config landed runs when it does.
    public func reloadConfig() {
        guard let configLoader else { return }
        guard isStarted else {
            reloadAfterStart = true
            return
        }
        guard app != nil else { return }
        reloadRequests &+= 1
        let (request, inputs) = (reloadRequests, configInputs(theme: nil))
        configLoader.load({ inputs.buildConfig() }) { [weak self] built in
            guard let built else { return }
            guard let self, request == self.reloadRequests, let app = self.app else { return built.free() }
            self.recordUserConfigLoad(built)
            self.adoptedDuringReload = false
            self.applyColorTransitionToSurfaces()
            // SAFETY: `app` is the live app (never freed); update_config copies what it keeps from
            // the built config, which this reply still owns.
            unsafe ghostty_app_update_config(app, built.config)
            // Ghostty answers with CONFIG_CHANGE on this thread: the config it
            // applied carries the light/dark variant, `built` does not (it
            // would put a dark app's chrome back on the light variant).
            // SAFETY: the built config leaves this reply by exactly one path: freed, or handed to
            // the runtime's `config`.
            if self.adoptedDuringReload { built.free() } else { unsafe self.replaceConfig(built.config) }
        }
    }

    /// Keeps what a build of the user's own config read (a theme config's is not kept).
    func recordUserConfigLoad(_ built: GhosttyBuiltConfig) {
        configuredBackgroundOpacity = built.opacity
        configDiagnostics = built.diagnostics
        GhosttyConfigBackground.loaded = GhosttyConfigBackground(opacity: built.filesOpacity, blur: built.filesBlur)
        GhosttyConfigFontFamily.recordLoad()
    }
}

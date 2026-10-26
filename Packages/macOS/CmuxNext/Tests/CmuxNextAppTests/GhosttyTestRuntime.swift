import CmuxNextDesign
@testable import CmuxNextTerminal

extension GhosttyConfigInputs {
    /// A build of `configFile` alone (with cmux's defaults under it): no cmux.json override, the light scheme.
    static func testing(configFile: String) -> GhosttyConfigInputs {
        GhosttyConfigInputs(theme: nil, themeEdits: .none, isDark: false, font: .init(), background: .init(),
                            ownerPaintsBackground: false, configFile: configFile)
    }
}

extension GhosttyRuntime {
    /// The shared runtime, started. A test process has no app launch to build the first config on a lane
    /// (``GhosttyRuntime/start(loadingOn:then:)``), so the test builds it in its own turn and starts the runtime
    /// with it; the app's getters never build one.
    @MainActor @discardableResult static func startedForTests() -> GhosttyRuntime {
        let runtime = GhosttyRuntime.shared
        if !runtime.isStarted { runtime.start(with: GhosttyConfigInputs.current(theme: nil).buildConfig()) }
        return runtime
    }
}

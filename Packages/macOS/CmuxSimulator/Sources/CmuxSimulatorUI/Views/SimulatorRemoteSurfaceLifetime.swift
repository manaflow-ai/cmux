/// Owns teardown independently of AppKit window-transition callbacks.
@MainActor
final class SimulatorRemoteSurfaceLifetime {
    weak var view: SimulatorRemoteSurfaceView?

    deinit {
        MainActor.assumeIsolated {
            view?.teardown()
        }
    }
}

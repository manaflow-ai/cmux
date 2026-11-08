#if DEBUG
import CmuxSimulator

extension SimulatorPaneCoordinator {
    /// Terminates the isolated renderer so containment recovery can be verified.
    public func terminateRenderer() {
        enqueue(.terminateRenderer)
    }
}
#endif

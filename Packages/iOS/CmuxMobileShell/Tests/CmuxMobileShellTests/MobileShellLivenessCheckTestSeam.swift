@testable import CmuxMobileShell

@MainActor
extension MobileShellComposite {
    /// Test-target seam replacing the removed production debug hook: run one
    /// liveness evaluation for the currently armed watchdog generation,
    /// exactly as a DispatchSourceTimer tick would, against the injected clock.
    func runRenderGridLivenessCheckForTesting() {
        guard let listenerID = renderGridLivenessListenerID else { return }
        checkRenderGridLiveness(listenerID: listenerID)
    }
}

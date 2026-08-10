#if DEBUG
import CMUXMobileCore
public import CmuxMobileShell

extension MobileShellComposite {
    /// Enables Simulator streaming for a deterministic debug fixture.
    public func enableSimulatorStreamPreviewCapability() {
        supportedHostCapabilities.insert(MobileSimulatorStreamCapability.current.identifier)
    }
}
#endif

#if DEBUG
extension MobileShellComposite {
    /// Enables the Simulator-stream capability for an isolated debug preview instance.
    public func enableSimulatorStreamPreviewCapability() {
        supportedHostCapabilities.insert(Self.simulatorStreamCapability)
    }
}
#endif

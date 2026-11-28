import CmuxMobileRPC

extension MobileShellComposite {
    /// Whether the foreground Mac advertises the Chief control surface.
    public var supportsChief: Bool {
        connectionState == .connected
            && MobileChiefCapability.isAvailable(in: supportedHostCapabilities)
    }

    /// Creates a Chief client over the same foreground connection used by the
    /// workspace shell. The client is short-lived and shares the RPC session;
    /// callers should keep it for the lifetime of the Chief presentation.
    public func makeChiefClient() -> MobileChiefClient? {
        guard supportsChief, let client = remoteClient else { return nil }
        return MobileChiefClient(client: client)
    }
}

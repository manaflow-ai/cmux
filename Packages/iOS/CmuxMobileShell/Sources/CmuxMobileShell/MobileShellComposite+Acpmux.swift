import CmuxMobileRPC

extension CMUXMobileShellStore {
    /// The authenticated foreground control client for the independent
    /// ACPmux surface. This accessor keeps the UI from depending on any of
    /// the older agent-chat types.
    public var acpmuxClient: MobileCoreRPCClient? { remoteClient }
}


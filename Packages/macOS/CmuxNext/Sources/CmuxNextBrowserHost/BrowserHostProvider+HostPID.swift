extension BrowserHostProvider {
    /// The connected browser host's pid: the daemon's `browser-host-provider` answer, which the link checked against
    /// the socket's peer. Nil while no host is connected. The resource samples read it (p09-observability-121).
    public var connectedHostPID: Int32? {
        guard connection != nil, let pid = currentCredentials?.hostPID, pid > 0 else { return nil }
        return pid
    }
}

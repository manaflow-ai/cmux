/// ``RemoteDaemonProxyTunnel`` already exposes the exact
/// ``RemoteProxyTunneling`` surface; the conformance is declared here so the
/// broker depends on the protocol seam rather than the concrete tunnel.
extension RemoteDaemonProxyTunnel: RemoteProxyTunneling {}

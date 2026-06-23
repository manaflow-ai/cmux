public import CmuxCore

/// Proxy availability update delivered to ``RemoteProxyBroker`` subscribers.
///
/// Wire-facing strings inside `.error` are pinned: session controllers
/// forward them verbatim into connection-state details.
public enum RemoteProxyBrokerUpdate: Equatable, Sendable {
    /// The shared tunnel for the transport is starting (or restarting).
    case connecting
    /// The tunnel is up and reachable at `endpoint`.
    case ready(BrowserProxyEndpoint)
    /// The tunnel failed; `detail` carries the user-facing failure text
    /// including the retry suffix.
    case error(String)
}

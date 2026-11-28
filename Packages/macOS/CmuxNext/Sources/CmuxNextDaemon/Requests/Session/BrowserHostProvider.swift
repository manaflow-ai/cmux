import Foundation

/// `browser-host-provider` (`browser-host-provider-v1`): the provider credentials of the
/// daemon's browser host. The daemon answers only the verified app connection (role `main`
/// plus a proof); the secret must never be logged or stored.
public struct BrowserHostProviderRequest: DaemonRequest {
    public typealias Response = BrowserHostProviderResult
    public static let command = "browser-host-provider"
    public init() {}
}

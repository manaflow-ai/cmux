import Foundation

/// Ends the calling connection's credential scope on the local daemon.
/// Only the verified current credential provider may call this; it takes no object IDs.
public struct AppsProviderScopeChangedRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "apps-provider-scope-changed"

    /// Creates a notification that invalidates the provider's existing Cloud resources.
    public init() {}
}

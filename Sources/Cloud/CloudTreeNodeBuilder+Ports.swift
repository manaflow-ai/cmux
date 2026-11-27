import CmuxSurfaceCatalogModel
import Foundation

extension CloudTreeNodeBuilder {
    /// Returns canonical forwarded-port resources in stable port/key order.
    ///
    /// The tree treats any orphan browser resource with a listening port as a
    /// port row; this narrower helper is retained for callers that need to
    /// distinguish provider-minted `port:<n>` resources from ordinary daemon
    /// browser tabs that happen to point at localhost.
    static func portResources(_ resources: [SurfaceResource]) -> [SurfaceResource] {
        resources
            .filter { $0.kind == .browser && $0.port != nil && $0.id.key.hasPrefix("port:") }
            .sorted { ($0.port ?? 0, $0.id.key) < ($1.port ?? 0, $1.id.key) }
    }
}

/// Enrolls this Mac's Cloud Tunnel peer (`POST /api/vm/tunnel`, purpose `browser`) with a fresh
/// key and returns the completed wg-quick config. A seam so the controller does not depend on the
/// Cloud API client; the app composes it.
public protocol CloudTunnelEnrolling: Sendable {
    /// - Returns: The server's config with this Mac's private key filled in.
    func enrollBrowserPeer() async throws -> String
}

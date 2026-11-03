/// A ``CloudTunnelEnrolling`` made of a closure, so the app composes the Cloud API client's
/// enrollment without this package depending on it.
///
/// ```swift
/// let enroller = CloudTunnelEnroller { try await browserEnroller.enrollBrowserPeer() }
/// ```
public struct CloudTunnelEnroller: CloudTunnelEnrolling {
    private let enroll: @Sendable () async throws -> String

    /// - Parameter enroll: Enrolls the `browser` peer and returns its completed wg-quick config.
    public init(_ enroll: @escaping @Sendable () async throws -> String) {
        self.enroll = enroll
    }

    public func enrollBrowserPeer() async throws -> String {
        try await enroll()
    }
}

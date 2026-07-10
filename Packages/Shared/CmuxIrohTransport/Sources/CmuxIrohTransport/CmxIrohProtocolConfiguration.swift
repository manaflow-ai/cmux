public import Foundation

/// Immutable limits and identifiers for one cmux Iroh protocol version.
public struct CmxIrohProtocolConfiguration: Equatable, Sendable {
    /// The ALPN negotiated by cmux Iroh endpoints.
    public let alpn: Data

    /// The largest accepted stream-header frame, including its fixed prefix.
    public let maximumHeaderByteCount: Int

    /// Creates a protocol configuration.
    ///
    /// - Parameters:
    ///   - alpn: The application protocol identifier advertised through QUIC.
    ///   - maximumHeaderByteCount: The inclusive stream-header size limit.
    public init(alpn: Data, maximumHeaderByteCount: Int) {
        self.alpn = alpn
        self.maximumHeaderByteCount = maximumHeaderByteCount
    }

    /// The production `cmux/mobile/1` protocol configuration.
    public static let cmuxMobileV1 = CmxIrohProtocolConfiguration(
        alpn: Data("cmux/mobile/1".utf8),
        maximumHeaderByteCount: 16 * 1_024
    )
}

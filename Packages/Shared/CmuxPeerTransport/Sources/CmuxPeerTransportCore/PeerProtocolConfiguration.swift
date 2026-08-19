public import Foundation

/// Immutable identifiers and limits for one cmux peer protocol version.
public struct PeerProtocolConfiguration: Equatable, Sendable {
    /// The ALPN negotiated by cmux peer endpoints.
    public let alpn: Data

    /// The marker beginning every lane-header frame.
    public let headerMagic: Data

    /// The lane-header wire version encoded after the magic.
    public let headerVersion: UInt8

    /// The largest accepted lane-header frame, including its fixed prefix.
    public let maximumHeaderByteCount: Int

    /// Creates a protocol configuration.
    ///
    /// - Parameters:
    ///   - alpn: The application protocol identifier advertised through QUIC.
    ///   - headerMagic: The exact bytes every lane header must begin with.
    ///   - headerVersion: The single lane-header version this build speaks.
    ///   - maximumHeaderByteCount: The inclusive lane-header size limit.
    public init(
        alpn: Data,
        headerMagic: Data,
        headerVersion: UInt8,
        maximumHeaderByteCount: Int
    ) {
        self.alpn = alpn
        self.headerMagic = headerMagic
        self.headerVersion = headerVersion
        self.maximumHeaderByteCount = maximumHeaderByteCount
    }

    /// The production `cmux/mobile/2` protocol configuration.
    ///
    /// The header bound carries over from `cmux/mobile/1`: large enough for a
    /// 12 KiB pair-grant JWS plus framing, small enough to reject a hostile
    /// declared length before buffering.
    public static let cmuxMobileV2 = PeerProtocolConfiguration(
        alpn: Data("cmux/mobile/2".utf8),
        headerMagic: Data("CMUXPRT2".utf8),
        headerVersion: 1,
        maximumHeaderByteCount: 16 * 1_024
    )
}

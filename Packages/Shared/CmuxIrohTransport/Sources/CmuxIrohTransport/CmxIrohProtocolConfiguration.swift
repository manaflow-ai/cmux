public import Foundation

/// Immutable limits and identifiers for one cmux Iroh protocol version.
public struct CmxIrohProtocolConfiguration: Equatable, Sendable {
    /// Hard ceiling for opt-in client-created terminal and artifact streams.
    public static let maximumClientApplicationLaneCount: UInt64 = 16

    /// The ALPN negotiated by cmux Iroh endpoints.
    public let alpn: Data

    /// The largest accepted stream-header frame, including its fixed prefix.
    public let maximumHeaderByteCount: Int

    /// Additional client-created bidirectional lanes credited after admission.
    ///
    /// Production v1 leaves this at zero until an application lane owner is
    /// installed. Test and future negotiated configurations may opt in up to
    /// ``maximumClientApplicationLaneCount`` without weakening bootstrap limits.
    public let maximumConcurrentClientApplicationLaneCount: UInt64

    /// Whether an admitted connection may activate direct paths after both
    /// peers have completed the authenticated admission barrier.
    ///
    /// Production keeps this enabled. Debug hosts can disable it to verify the
    /// relay path without changing the ALPN or weakening admission.
    public let allowsNATTraversalAfterAdmission: Bool

    /// Creates a protocol configuration.
    ///
    /// - Parameters:
    ///   - alpn: The application protocol identifier advertised through QUIC.
    ///   - maximumHeaderByteCount: The inclusive stream-header size limit.
    public init(
        alpn: Data,
        maximumHeaderByteCount: Int,
        maximumConcurrentClientApplicationLaneCount: UInt64 = 0,
        allowsNATTraversalAfterAdmission: Bool = true
    ) {
        precondition(
            maximumConcurrentClientApplicationLaneCount
                <= Self.maximumClientApplicationLaneCount
        )
        self.alpn = alpn
        self.maximumHeaderByteCount = maximumHeaderByteCount
        self.maximumConcurrentClientApplicationLaneCount =
            maximumConcurrentClientApplicationLaneCount
        self.allowsNATTraversalAfterAdmission = allowsNATTraversalAfterAdmission
    }

    /// The production `cmux/mobile/1` protocol configuration.
    public static let cmuxMobileV1 = CmxIrohProtocolConfiguration(
        alpn: Data("cmux/mobile/1".utf8),
        maximumHeaderByteCount: 16 * 1_024,
        maximumConcurrentClientApplicationLaneCount: 0
    )
}

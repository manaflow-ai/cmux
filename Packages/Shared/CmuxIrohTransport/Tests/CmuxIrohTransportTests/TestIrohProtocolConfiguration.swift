import CMUXMobileCore
import Foundation
@testable import CmuxIrohTransport

extension CmxIrohProtocolConfiguration {
    static let testApplicationLanes = CmxIrohProtocolConfiguration(
        alpn: Data("cmux/mobile/1".utf8),
        maximumHeaderByteCount: 16 * 1_024,
        maximumConcurrentClientApplicationLaneCount: 16
    )

    static let testRelayOnlyApplicationLanes = CmxIrohProtocolConfiguration(
        alpn: Data("cmux/mobile/1".utf8),
        maximumHeaderByteCount: 16 * 1_024,
        maximumConcurrentClientApplicationLaneCount: 16,
        allowsNATTraversalAfterAdmission: false
    )

    static let testDirectOnlyApplicationLanes = CmxIrohProtocolConfiguration(
        alpn: Data("cmux/mobile/1".utf8),
        maximumHeaderByteCount: 16 * 1_024,
        maximumConcurrentClientApplicationLaneCount: 16,
        allowsNATTraversalAfterAdmission:
            CmxIrohTransportVerificationMode.directOnly
                .allowsNATTraversalAfterAdmission
    )
}

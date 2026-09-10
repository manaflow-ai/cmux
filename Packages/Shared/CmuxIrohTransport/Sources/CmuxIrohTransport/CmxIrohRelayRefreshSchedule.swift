import CMUXMobileCore
import Foundation

/// Assigns endpoint-stable, non-overlapping relay credential refresh slots.
struct CmxIrohRelayRefreshSchedule: Sendable {
    enum Role: Sendable {
        case host
        case client

        fileprivate var phaseStart: Int {
            switch self {
            case .host: 0
            case .client: 30
            }
        }
    }

    private static let phaseWidth = 15
    private static let minuteDuration: TimeInterval = 60
    private static let fnvOffsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let fnvPrime: UInt64 = 1_099_511_628_211

    private let secondWithinMinute: Int

    init(role: Role, endpointIdentity: CmxIrohPeerIdentity) {
        var hash = Self.fnvOffsetBasis
        for byte in endpointIdentity.endpointID.utf8 {
            hash ^= UInt64(byte)
            hash &*= Self.fnvPrime
        }
        secondWithinMinute = role.phaseStart + Int(hash % UInt64(Self.phaseWidth))
    }

    func deadline(now: Date, refreshAfter: Date) -> Date {
        let refreshEpoch = refreshAfter.timeIntervalSince1970
        let minuteStart = floor(refreshEpoch / Self.minuteDuration)
            * Self.minuteDuration
        var candidateEpoch = minuteStart + TimeInterval(secondWithinMinute)
        if candidateEpoch > refreshEpoch {
            candidateEpoch -= Self.minuteDuration
        }
        return min(
            refreshAfter,
            max(now, Date(timeIntervalSince1970: candidateEpoch))
        )
    }
}

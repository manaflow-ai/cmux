import CMUXMobileCore
import Foundation

/// Identifies the externally visible reachability state last published to the broker.
struct CmxIrohRegistrationPublicationState: Equatable, Sendable {
    private struct Fingerprint: Equatable, Sendable {
        let routeKeys: [String]
        let directPorts: CmxIrohDirectPorts?

        init(payload: CmxIrohRegistrationPayload) {
            routeKeys = payload.pathHints.map(Self.routeKey).sorted()
            directPorts = payload.directPorts
        }

        private static func routeKey(_ hint: CmxIrohPathHint) -> String {
            [
                hint.kind.rawValue,
                hint.value,
                hint.source.rawValue,
                hint.privacyScope.rawValue,
                hint.networkProfile?.source.rawValue ?? "",
                hint.networkProfile?.profileID ?? "",
            ].joined(separator: "\u{1F}")
        }
    }

    private static let maximumPublicationInterval: TimeInterval = 50 * 60
    private static let hintRefreshLeadTime: TimeInterval = 5 * 60

    private let fingerprint: Fingerprint
    private let refreshAfter: Date

    init(payload: CmxIrohRegistrationPayload, now: Date) {
        let hintRefreshAfter = payload.pathHints.compactMap(\.expiresAt).min()
            .map { $0.addingTimeInterval(-Self.hintRefreshLeadTime) }
        let intervalRefreshAfter = now.addingTimeInterval(
            Self.maximumPublicationInterval
        )
        fingerprint = Fingerprint(payload: payload)
        refreshAfter = min(
            hintRefreshAfter ?? intervalRefreshAfter,
            intervalRefreshAfter
        )
    }

    func requiresPublication(
        after previous: CmxIrohRegistrationPublicationState?,
        now: Date
    ) -> Bool {
        guard let previous,
              previous.fingerprint == fingerprint else { return true }
        return now >= previous.refreshAfter
    }
}

import CMUXMobileCore
import Foundation

/// Identifies the externally visible reachability state last published to the broker.
struct CmxIrohRegistrationPublicationState: Equatable, Sendable {
    private struct Fingerprint: Equatable, Sendable {
        /// Reachability facts whose change must publish at once: relay URLs,
        /// signed direct ports, and whether any direct address exists at all.
        /// A peer that cannot reach the host through these is offline until
        /// the broker learns the new value.
        let stableKeys: [String]
        let directPorts: CmxIrohDirectPorts?
        let hasDirectAddresses: Bool
        /// Observed direct addresses. A NAT rebinding changes these every few
        /// seconds on some networks while the relay path stays valid, so a
        /// change here is coalesced by the spacing window.
        let volatileKeys: [String]

        init(payload: CmxIrohRegistrationPayload) {
            let direct = payload.pathHints.filter { $0.kind == .directAddress }
            stableKeys = payload.pathHints
                .filter { $0.kind != .directAddress }
                .map(Self.routeKey)
                .sorted()
            volatileKeys = direct.map(Self.routeKey).sorted()
            hasDirectAddresses = !direct.isEmpty
            directPorts = payload.directPorts
        }

        func stablePartEquals(_ other: Fingerprint) -> Bool {
            stableKeys == other.stableKeys
                && directPorts == other.directPorts
                && hasDirectAddresses == other.hasDirectAddresses
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

    /// What a runtime should do with a freshly computed publication state.
    enum Decision: Equatable, Sendable {
        /// Publish now: first registration, changed reachability past the
        /// spacing window, or a scheduled renewal.
        case publish
        /// Reachability is unchanged and no renewal is due.
        case unchanged
        /// Reachability changed inside the spacing window. Publish at `until`
        /// unless a later snapshot supersedes this one first.
        case deferred(until: Date)
    }

    private static let maximumPublicationInterval: TimeInterval = 50 * 60
    private static let hintRefreshLeadTime: TimeInterval = 5 * 60
    /// The shortest gap between two publications driven only by observed
    /// direct-address churn, when the broker has not advertised one.
    ///
    /// Observed addresses on a Mac behind a NAT can change every few seconds.
    /// Without a floor, every change became a signed registration round trip
    /// and a broker write; the fleet measured a median of 46 seconds between
    /// registrations per device. Changes inside the window are coalesced into
    /// one publication at the end of it. Renewals and forced publications are
    /// not subject to the floor.
    static let defaultMinimumPublicationSpacing: TimeInterval = 60

    private let fingerprint: Fingerprint
    private let refreshAfter: Date
    private let publishedAt: Date
    private let minimumSpacing: TimeInterval

    init(
        payload: CmxIrohRegistrationPayload,
        now: Date,
        minimumPublicationSpacing: TimeInterval = Self.defaultMinimumPublicationSpacing
    ) {
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
        publishedAt = now
        minimumSpacing = max(0, minimumPublicationSpacing)
    }

    /// The spacing floor is a property of the last publication: the broker
    /// advertises it on the register response that created `previous`.
    func publicationDecision(
        after previous: CmxIrohRegistrationPublicationState?,
        now: Date
    ) -> Decision {
        guard let previous else { return .publish }
        if now >= previous.refreshAfter { return .publish }
        guard previous.fingerprint.stablePartEquals(fingerprint) else { return .publish }
        guard previous.fingerprint != fingerprint else { return .unchanged }
        let earliest = previous.publishedAt.addingTimeInterval(previous.minimumSpacing)
        return now >= earliest ? .publish : .deferred(until: earliest)
    }

    func requiresPublication(
        after previous: CmxIrohRegistrationPublicationState?,
        now: Date
    ) -> Bool {
        publicationDecision(after: previous, now: now) == .publish
    }
}

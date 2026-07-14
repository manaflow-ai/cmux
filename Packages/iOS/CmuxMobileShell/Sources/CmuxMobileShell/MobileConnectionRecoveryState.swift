import Foundation

/// The foreground session recovery phase owned by one single-flight attempt.
enum MobileConnectionRecoveryState: Equatable {
    case resettingSession(UUID)
    case awaitingResetSubscription(UUID)
    case reconnectingStoredRoute(UUID)
    case awaitingStoredRouteSubscription(UUID)

    var id: UUID {
        switch self {
        case .resettingSession(let id),
             .awaitingResetSubscription(let id),
             .reconnectingStoredRoute(let id),
             .awaitingStoredRouteSubscription(let id):
            id
        }
    }
}

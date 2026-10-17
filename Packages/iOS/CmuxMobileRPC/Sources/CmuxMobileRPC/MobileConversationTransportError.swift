import Foundation

/// Transport failures are kept distinct from provider command rejections.
enum MobileConversationTransportError: Error, Sendable {
    case disconnected
    case invalidScope
    case invalidResponse
    case eventOverflow
}

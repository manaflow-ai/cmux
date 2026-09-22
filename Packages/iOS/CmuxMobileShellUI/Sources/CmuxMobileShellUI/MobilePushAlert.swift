#if os(iOS)
import Foundation

/// A user-facing result for a notification tap that could not navigate.
public struct MobilePushTabUnavailableAlert: Identifiable, Equatable, Sendable {
        /// The kind of recovery action the alert offers.
        public enum Kind: Equatable, Sendable {
            /// The requested workspace or terminal no longer exists.
            case tabUnavailable
            /// The Mac connection did not become usable before the retry window elapsed.
            case connectionUnavailable
        }

        /// Stable identity used by SwiftUI alert presentation.
        public let id: UUID
        /// The user-facing failure category.
        public let kind: Kind

        /// Creates an alert result.
        public init(id: UUID = UUID(), kind: Kind = .tabUnavailable) {
            self.id = id
            self.kind = kind
        }
}

public extension MobilePushCoordinator {
    /// The alert type exposed by the push coordinator.
    typealias TabUnavailableAlert = MobilePushTabUnavailableAlert
}
#endif

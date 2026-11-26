#if os(iOS)
import Foundation

/// A user-facing result for a notification tap that could not navigate.
public struct MobilePushTabUnavailableAlert: Identifiable, Equatable, Sendable {
        /// The kind of recovery action the alert offers.
        public typealias Kind = MobilePushTabUnavailableAlertKind

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

#endif

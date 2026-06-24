public import Foundation

/// A request to scroll a feed list to a specific row.
///
/// The feed list view bumps ``sequence`` each time the user (or an automation
/// seam) asks to scroll to ``id`` so that an otherwise-identical re-request
/// still compares unequal and re-triggers the scroll. Both fields are pure
/// values so the request can drive a SwiftUI `.onChange` without observing any
/// store.
public struct FeedScrollRequest: Equatable, Sendable {
    /// Identity of the row to scroll into view.
    public let id: UUID
    /// Monotonically increasing counter so repeated requests for the same row
    /// still compare unequal.
    public let sequence: Int

    /// Creates a scroll request for a row.
    /// - Parameters:
    ///   - id: Identity of the row to scroll into view.
    ///   - sequence: Monotonically increasing counter; repeated requests for
    ///     the same row must increment this so the request compares unequal.
    public init(id: UUID, sequence: Int) {
        self.id = id
        self.sequence = sequence
    }
}

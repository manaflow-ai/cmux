import Foundation
import Observation

/// A failed operation remains actionable until the user dismisses it or leaves the account.
@MainActor
@Observable
final class CloudTreeOperationErrorState {
    struct Failure: Identifiable, Equatable {
        let id = UUID()
        let message: String
    }

    private(set) var failure: Failure?

    func report(_ message: String) {
        failure = Failure(message: message)
    }

    /// A button from an older rendered message cannot dismiss a newer failure.
    func dismiss(_ id: UUID) {
        guard failure?.id == id else { return }
        failure = nil
    }

    func reset() {
        failure = nil
    }
}

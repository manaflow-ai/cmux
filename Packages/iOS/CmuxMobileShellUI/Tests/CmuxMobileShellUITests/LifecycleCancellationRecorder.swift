import Foundation

actor LifecycleCancellationRecorder {
    private var authorizationCancelled = false

    func recordAuthorizationCancellation(_ cancelled: Bool) {
        authorizationCancelled = cancelled
    }

    var didCancelAuthorization: Bool { authorizationCancelled }
}

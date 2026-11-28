import Foundation

/// In-flight credential-exchange work owned by a sign-in attempt.
struct AuthTrackedSignInExchange {
    let id: UUID
    let task: Task<String?, any Error>
    let completion: Task<Void, Never>
}

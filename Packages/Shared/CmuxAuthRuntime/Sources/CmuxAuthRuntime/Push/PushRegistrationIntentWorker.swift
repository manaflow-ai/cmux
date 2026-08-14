import Foundation

/// Owns one queue worker and the intent generation it may reconcile.
struct PushRegistrationIntentWorker {
    let id: UUID
    let intent: PushRegistrationIntent
    let task: Task<Void, Never>
}

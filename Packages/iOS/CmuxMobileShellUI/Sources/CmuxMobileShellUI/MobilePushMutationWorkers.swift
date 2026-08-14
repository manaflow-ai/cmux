import Foundation

/// Keeps the app-lifetime settings operation, timeout, and completion together
/// so a superseding intent can cancel every worker that belongs to one
/// mutation.
struct MobilePushMutationWorkers {
    let token: UUID
    let operation: Task<Void, Never>
    let timeout: Task<Void, Never>
    let completion: MobilePushMutationCompletion
}

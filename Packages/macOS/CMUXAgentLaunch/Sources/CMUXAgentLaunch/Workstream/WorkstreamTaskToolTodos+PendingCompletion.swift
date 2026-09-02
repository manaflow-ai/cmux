import Foundation

extension WorkstreamTaskToolTodos {
    /// The outcome attached to a pre-tool mutation once its post hook arrives.
    enum PendingCompletion: Sendable {
        case success(responseJSON: String?)
        case failure
    }
}

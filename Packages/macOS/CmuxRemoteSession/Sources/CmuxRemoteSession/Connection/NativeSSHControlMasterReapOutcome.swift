internal import Foundation

/// Outcome of one broker-authorized inherited-ControlMaster reap.
enum NativeSSHControlMasterReapOutcome: Sendable, Equatable {
    case reaped(eventID: UUID)
    case deferred(String)
    case ignored(String)
}

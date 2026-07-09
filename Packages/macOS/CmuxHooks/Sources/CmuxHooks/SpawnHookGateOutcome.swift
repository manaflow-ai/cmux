import Foundation

/// The result of evaluating the pre-spawn gate for one pending spawn.
public enum SpawnHookGateOutcome: Sendable, Equatable {
    /// The spawn may proceed with the included final values.
    case proceed(SpawnHookGrant)

    /// The spawn is denied and must not execute.
    case deny(reason: String)
}

import Foundation

/// Compare-and-restore token for one durable hook-session mutation.
///
/// Rollback succeeds only while the exact record written by the mutation is
/// still current, so a later hook can never be overwritten by compensation for
/// an app-side ownership claim that lost its final race.
struct ClaudeHookSessionMutationRollback {
    let sessionId: String
    let previousRecord: ClaudeHookSessionRecord?
    let committedRecord: ClaudeHookSessionRecord
}

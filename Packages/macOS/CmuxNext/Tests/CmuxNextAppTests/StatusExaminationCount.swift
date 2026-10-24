/// How many statuses a finished status run follower examined: its injected settings closure
/// (`followStatusRuns(_:behavior:visibility:post:)`) counts one per status it examines.
@MainActor final class StatusExaminationCount {
    var count = 0
}

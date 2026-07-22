import Foundation

/// Tracks which agent sessions have already had a resume command launched
/// during the current app process, so that two panels referencing the same
/// underlying agent session — a duplicate-workspace restore, a
/// restore-into-live, or two panels in the same restore pass — never both
/// fire `codex resume <id>` / `claude --resume <id>` concurrently (#8446).
///
/// A claim is scoped to the process's lifetime: a fresh app launch gets a
/// fresh `.shared` instance, so there is nothing to reset between launches.
@MainActor
final class AgentResumeLaunchGuard {
    static let shared = AgentResumeLaunchGuard()

    init() {}

    /// Attempts to claim the resume launch for `(kind, sessionId)`.
    ///
    /// Returns `true` the first time a given session is claimed, meaning the
    /// caller should proceed with firing the resume. Returns `false` on every
    /// subsequent call for the same session, meaning some other panel already
    /// claimed it and the caller must skip firing a duplicate resume.
    // TODO(#8446): this does not yet track claims, so every caller is told
    // it's free to launch — restore this to the real dedup once verified.
    @discardableResult
    func claimResumeLaunch(kind: String, sessionId: String) -> Bool {
        true
    }
}

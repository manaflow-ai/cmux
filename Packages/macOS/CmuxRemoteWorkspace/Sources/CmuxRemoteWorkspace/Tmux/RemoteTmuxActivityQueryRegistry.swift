public import Foundation

/// In-flight registry of close-time pane-activity queries for a single tmux
/// control connection.
///
/// Each query is a `([Int: RemoteTmuxPaneForegroundState]?) -> Void` completion
/// keyed by an opaque `UUID` token, registered when the query is written on the
/// control stream and resumed exactly once: with the parsed per-pane states when
/// the matching `%begin`/`%end` result arrives, or with `nil` when the query
/// could not be issued, the result errored, or the control stream became
/// unusable (reconnect begins, deliberate stop, genuine `%exit`). A `nil` result
/// lets a pending close decision fall back to the cached classification instead
/// of hanging until a reconnect that may never come.
///
/// The owning connection keeps `connectionState`, the send path, and the
/// pane-foreground-state cache; this type owns only the token→completion map and
/// drains it on demand. Mirrors ``RemoteTmuxConnectionWaiters``.
@MainActor
public final class RemoteTmuxActivityQueryRegistry {
    /// The per-query completion: the parsed per-pane foreground states, or `nil`
    /// when the query could not be answered.
    public typealias Completion = ([Int: RemoteTmuxPaneForegroundState]?) -> Void

    private var completions: [UUID: Completion] = [:]

    public init() {}

    /// Registers `completion` under `token`. Resumed and dropped by a later
    /// ``removeCompletion(for:)`` or ``failAll()`` call.
    public func register(_ token: UUID, _ completion: @escaping Completion) {
        completions[token] = completion
    }

    /// Removes the completion registered for `token` (if any) and returns it
    /// WITHOUT invoking it, so the caller resumes it with the appropriate result
    /// (the parsed states on success, or `nil` on a per-query error).
    public func removeCompletion(for token: UUID) -> Completion? {
        completions.removeValue(forKey: token)
    }

    /// Fails every in-flight query with `nil` and drops it, so a pending close
    /// decision falls back to the cached classification.
    public func failAll() {
        guard !completions.isEmpty else { return }
        let pending = Array(completions.values)
        completions.removeAll()
        for completion in pending {
            completion(nil)
        }
    }
}

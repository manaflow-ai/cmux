import Foundation

/// Resolves hookless agent observations (bare launches that bypassed the hook
/// wrapper, known only as "an agent-named process on a pane TTY") to concrete
/// session ids from the workspace cwd's session files.
///
/// A `ps` basename plus a file mtime is not a reliable identity: two
/// same-agent sessions in one cwd, a wrapper binary named `codex`/`claude`,
/// or a just-resumed stale transcript can all look alike. Binding the wrong
/// session would make the Notes tree attach notes to — or resume — the wrong
/// conversation, so resolution fails closed: an observation binds only when
/// exactly one live session matches it. Ambiguous panes stay unbound until a
/// hook record supplies real identity.
enum NotesTreeAnonymousResolution {
    /// 120s slack: a just-resumed session's file mtime can slightly predate
    /// the process start.
    static let startSlack: TimeInterval = 120

    static func resolve(
        anonymous: [NotesTreeAnonymousAgentObservation],
        liveSessions: [NotesSessionDescriptor],
        workspaceCwd: String
    ) -> [NotesTreeObservedSession] {
        guard !anonymous.isEmpty else { return [] }
        let cwdLive = liveSessions
            .filter { ($0.cwd as NSString).standardizingPath == workspaceCwd }
            .sorted { $0.modified > $1.modified }
        guard !cwdLive.isEmpty else { return [] }
        var taken = Set<String>()
        var resolved: [NotesTreeObservedSession] = []
        for anon in anonymous {
            let candidates = cwdLive.filter { candidate in
                candidate.agent == anon.agent
                    && candidate.modified >= anon.startedAt - startSlack
                    && !taken.contains("\(candidate.agent)\n\(candidate.sessionId)")
            }
            guard candidates.count == 1, let match = candidates.first else { continue }
            taken.insert("\(match.agent)\n\(match.sessionId)")
            resolved.append(NotesTreeObservedSession(
                agent: match.agent,
                sessionId: match.sessionId,
                surfaceAnchorId: anon.surfaceAnchorId,
                terminalPanelId: anon.terminalPanelId
            ))
        }
        return resolved
    }
}

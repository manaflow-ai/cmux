import Foundation

/// What a restart of one server keeps and what it loses, for the confirm.
public nonisolated struct ServerRestartImpact: Sendable, Equatable {
    /// Sentences about what keeps running.
    public var kept: [String]
    /// Sentences about what is lost.
    public var lost: [String]
    /// True when running work ends (an acpmux without agent hosts): the Restart button is
    /// destructive and never the Return default.
    public var isDestructive: Bool

    /// The impact of restarting `kind`; `keepsWork` is the handshake's
    /// ``ServerHandshake/keepsWorkAcrossRestart``.
    public init(kind: ServerKind, keepsWork: Bool) {
        switch (kind, keepsWork) {
        case (.cmuxTUI, _):
            kept = [UpdaterStrings.text("server.impact.kept.terminals", "Kept: every terminal, its shell, running programs and scrollback.")]
            lost = [UpdaterStrings.text("server.impact.lost.reconnect", "Lost: a short reconnect. A CLI command running at that moment fails and can be run again.")]
            isDestructive = false
        case (.acpmux, true):
            kept = [UpdaterStrings.text("server.impact.kept.agents", "Kept: every agent session and its history. Agents keep running.")]
            lost = [UpdaterStrings.text("server.impact.lost.turns", "Lost: a Chief or agent turn in progress may stop.")]
            isDestructive = false
        case (.acpmux, false):
            kept = [UpdaterStrings.text("server.impact.kept.history", "Kept: chat history.")]
            lost = [UpdaterStrings.text("server.impact.lost.agents", "Lost: running agents end, and their turns in progress are lost.")]
            isDestructive = true
        }
    }
}

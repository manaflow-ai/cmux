import Foundation

/// One rendered session row: what the AppKit line draws, already formatted.
/// Part of `SidebarWorkspaceRowModel`, so it is Equatable and drives both the
/// live cell and the height-cache prototype.
struct SidebarRowAgentSessionDisplay: Equatable, Identifiable {
    /// Marks the one session the user most recently typed into.
    static let lastTypedMarker = "◀"
    /// Prefix of the last-prompt line.
    static let promptPrefix = "↳ "

    let panelId: UUID
    var id: UUID { panelId }
    let title: String
    let state: SidebarAgentSessionSnapshot.State
    /// "12m", or "12m ◀" on the last-typed row. `var` only so
    /// `neutralizingAge()` can blank it for height comparisons.
    var ageText: String
    let isLastTyped: Bool
    /// "↳ <prompt>", nil when the prompt line is hidden for this row.
    let promptLine: String?
    /// Full title, blank line, full prompt (title only without a prompt).
    let toolTip: String
    let accessibilityLabel: String

    /// The same row with the ticking age removed, for height equivalence.
    func neutralizingAge() -> Self {
        var copy = self
        copy.ageText = ""
        return copy
    }
}

/// Turns workspace session snapshots into display rows for one point in time.
struct SidebarRowAgentSessionPresenter {
    let now: Date
    let lastTypedPanelId: UUID?
    var formatter = SidebarAgentSessionAgeFormatter()

    /// - Parameter isActive: whether the workspace is the selected one; the
    ///   prompt line shows for every session of the selected workspace and for
    ///   the last-typed session anywhere.
    func rows(for sessions: [SidebarAgentSessionSnapshot], isActive: Bool) -> [SidebarRowAgentSessionDisplay] {
        sessions.map { session in
            let isLastTyped = lastTypedPanelId == session.panelId
            var ageText = formatter.text(from: session.lastActivityMinute, now: now)
            if isLastTyped {
                ageText += " " + SidebarRowAgentSessionDisplay.lastTypedMarker
            }
            let prompt = session.lastPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
            let promptLine: String? = {
                guard isActive || isLastTyped, let prompt, !prompt.isEmpty else { return nil }
                return SidebarRowAgentSessionDisplay.promptPrefix + prompt
            }()
            let toolTip = prompt.map { "\(session.title)\n\n\($0)" } ?? session.title
            let stateLabel: String
            switch session.state {
            case .running:
                stateLabel = String(localized: "sidebar.agentSession.state.running", defaultValue: "running")
            case .idle:
                stateLabel = String(localized: "sidebar.agentSession.state.idle", defaultValue: "idle")
            case .needsInput:
                stateLabel = String(localized: "sidebar.agentSession.state.needsInput", defaultValue: "needs input")
            }
            return SidebarRowAgentSessionDisplay(
                panelId: session.panelId,
                title: session.title,
                state: session.state,
                ageText: ageText,
                isLastTyped: isLastTyped,
                promptLine: promptLine,
                toolTip: toolTip,
                accessibilityLabel: "\(session.agentName): \(session.title), \(stateLabel), \(ageText)"
            )
        }
    }

    /// Age of the newest session activity in the workspace, for the title line.
    func newestAgeText(for sessions: [SidebarAgentSessionSnapshot]) -> String? {
        guard let newest = sessions.map(\.lastActivityMinute).max() else { return nil }
        return formatter.text(from: newest, now: now)
    }
}

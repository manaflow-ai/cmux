import CmuxTerminalSizing

/// Everything a Mac view needs to draw one terminal's sharing state.
public struct TerminalSharingSnapshot: Hashable, Sendable {
    /// The host's published state.
    public var state: TerminalSizingState
    /// This Mac view's participant id in `state`, when known.
    public var selfParticipantID: String?
    /// Set while this Mac view is detached and must not reconnect by itself.
    public var detachment: TerminalSharingDetachment?
    /// Whether this is a Cloud terminal (cmux-tui host) rather than a local one.
    public var isCloud: Bool

    /// Creates a snapshot.
    ///
    /// - Parameters:
    ///   - state: the host's published state.
    ///   - selfParticipantID: this view's participant id.
    ///   - detachment: a detach this view must show.
    ///   - isCloud: whether a cmux-tui daemon hosts the terminal.
    public init(
        state: TerminalSizingState,
        selfParticipantID: String?,
        detachment: TerminalSharingDetachment? = nil,
        isCloud: Bool
    ) {
        self.state = state
        self.selfParticipantID = selfParticipantID
        self.detachment = detachment
        self.isCloud = isCloud
    }

    /// This view's row, when attached.
    public var selfParticipant: TerminalSizingParticipantState? {
        selfParticipantID.flatMap { state.participant($0) }
    }

    /// Whether this view's own grid equals the terminal grid.
    public var selfMatchesGrid: Bool {
        guard let viewport = selfParticipant?.participant.viewport else { return true }
        return viewport == state.size
    }

    /// Participants other than this view that can be disconnected.
    public var otherParticipantIDs: [String] {
        state.participants.map(\.id).filter { $0 != selfParticipantID }
    }

    /// Whether anyone else views the terminal, which is when sharing UI appears.
    public var isShared: Bool { !otherParticipantIDs.isEmpty || detachment != nil }

    /// The participant that owns the grid, when exactly one does.
    public var owner: TerminalSizingParticipantState? { state.soleOwner }
}

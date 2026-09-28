public import CmuxTerminalSizing

/// The facts the terminal bounds UI and the size sheet show, derived from a
/// published size state and this phone's own viewport.
public struct MobileTerminalSizingPresentation: Equatable, Sendable {
    /// The shared grid.
    public let grid: TerminalGridSize
    /// Why the grid has its size.
    public let reason: TerminalSizingReason
    /// The policy in force.
    public let policy: TerminalSizingPolicy
    /// The participant that sets the grid, when one does.
    public let owner: TerminalSizingParticipantState?
    /// Every participant that sets a dimension (several under smallest/largest).
    public let ownerIDs: [String]
    /// Whether this phone sets the grid.
    public let ownerIsSelf: Bool
    /// The color of the border, from the owner (or this phone when no one owns).
    public let ownerColor: MobileTerminalSizingParticipantColor
    /// This phone's participant row, when the host listed it.
    public let selfParticipant: TerminalSizingParticipantState?
    /// Every other participant, in host order.
    public let otherParticipants: [TerminalSizingParticipantState]
    /// This phone's viewport, when known.
    public let viewer: TerminalGridSize?

    /// Creates the presentation.
    /// - Parameters:
    ///   - state: The published size state.
    ///   - selfParticipantID: This phone's participant id.
    ///   - localViewport: The viewport this phone last reported. It wins over
    ///     the host's copy because it is newer.
    public init(
        state: TerminalSizingState,
        selfParticipantID: String?,
        localViewport: TerminalGridSize?
    ) {
        grid = state.size
        reason = state.reason
        policy = state.policy
        let owner = state.soleOwner ?? state.owners.first.flatMap { state.participant($0) }
        self.owner = owner
        ownerIDs = state.owners
        ownerIsSelf = owner != nil && owner?.id == selfParticipantID
        let selfRow = selfParticipantID.flatMap { state.participant($0) }
        selfParticipant = selfRow
        otherParticipants = state.participants.filter { $0.id != selfParticipantID }
        viewer = localViewport ?? selfRow?.participant.viewport
        if let owner {
            ownerColor = MobileTerminalSizingParticipantColor(participant: owner.participant)
        } else {
            ownerColor = MobileTerminalSizingParticipantColor(
                key: selfRow?.participant.userID ?? selfParticipantID ?? ""
            )
        }
    }

    /// Whether this phone's viewport differs from the grid.
    public var viewportDiffers: Bool {
        guard let viewer else { return false }
        return viewer != grid
    }

    /// Columns of the grid this phone cannot show.
    public var hiddenColumns: Int {
        guard let viewer else { return 0 }
        return max(0, grid.cols - viewer.cols)
    }

    /// Rows of the grid this phone cannot show.
    public var hiddenRows: Int {
        guard let viewer else { return 0 }
        return max(0, grid.rows - viewer.rows)
    }

    /// Whether the corner chip shows: the viewport differs, or another view
    /// shares the terminal.
    public var showsChip: Bool {
        viewportDiffers || !otherParticipants.isEmpty
    }

    /// Whether this phone's own row counts toward size.
    public var selfCounts: Bool {
        selfParticipant?.counts ?? false
    }

    /// The first word of a display name, used for "Maya's Mac Studio".
    /// - Parameter displayName: The full display name.
    /// - Returns: The first whitespace-separated word, or `nil` when empty.
    public static func givenName(_ displayName: String?) -> String? {
        guard let displayName else { return nil }
        return displayName
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init)
    }
}

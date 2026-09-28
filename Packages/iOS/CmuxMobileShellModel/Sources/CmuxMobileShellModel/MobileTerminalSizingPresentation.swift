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

    /// Whether the size chip shows. It shows only while this phone's
    /// viewport differs from the grid, together with the border and hatch.
    public var showsChip: Bool {
        viewportDiffers
    }

    /// Whether a participant sets a dimension of the grid.
    /// - Parameter participantID: The host's participant id.
    public func isOwner(_ participantID: String) -> Bool {
        ownerIDs.contains(participantID)
    }

    /// Who the size chip and the sheet header name as the size owner.
    public var ownerLabel: MobileTerminalSizingOwnerLabel {
        guard let owner else { return .policy(policy.mode) }
        if ownerIsSelf { return .thisDevice(owner.participant.deviceKind) }
        return MobileTerminalSizingOwnerLabel(participant: owner.participant)
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

/// The owner name the sizing UI shows, before localization.
public enum MobileTerminalSizingOwnerLabel: Equatable, Sendable {
    /// This phone or tablet sets the size.
    case thisDevice(TerminalDeviceKind)
    /// A named person's device: "Maya's Mac Studio", or "Maya" without a
    /// device name.
    case person(givenName: String, device: String?)
    /// A device name that stands alone. Used when there is no person name,
    /// or when the device name already contains it ("Maya's MacBook Pro").
    case device(String)
    /// Neither a person name nor a device name.
    case unnamed
    /// No participant sets the size; the policy does.
    case policy(TerminalSizingMode)

    /// The label for another participant.
    /// - Parameter participant: The participant.
    public init(participant: TerminalSizingParticipant) {
        let device = participant.deviceName.flatMap { $0.isEmpty ? nil : $0 }
        guard let given = MobileTerminalSizingPresentation.givenName(participant.displayName) else {
            self = device.map { .device($0) } ?? .unnamed
            return
        }
        if let device, device.localizedCaseInsensitiveContains(given) {
            self = .device(device)
        } else {
            self = .person(givenName: given, device: device)
        }
    }
}

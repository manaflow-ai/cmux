import Foundation
import CmuxTerminalSizing

/// The words shared-terminal UI puts around names and sizes.
///
/// The app passes localized strings; tests use ``english``. Keeping the
/// templates injectable lets the label rules below live in this package and be
/// tested without the app's string catalog.
public struct TerminalSharingStrings: Sendable {
    /// Label for this view's own participant, e.g. `This Mac`.
    public var thisMac: String
    /// Joins two parts with a middle dot, e.g. `Maya Ortiz · Mac Studio`.
    public var pair: @Sendable (String, String) -> String
    /// A person's device, e.g. `Lawrence's Mac` from `Lawrence` and `Mac`.
    public var possessiveDevice: @Sendable (String, String) -> String
    /// A device kind, e.g. `iPhone`.
    public var deviceKind: @Sendable (TerminalDeviceKind) -> String
    /// Owner label for a fixed grid.
    public var ownerFixed: String
    /// Owner label for `smallest`.
    public var ownerFitsEveryone: String
    /// Owner label for `largest`.
    public var ownerLargest: String
    /// Owner label while nobody counts and the size is held.
    public var ownerHeld: String
    /// Owner label when several participants set the grid.
    public var ownerShared: String
    /// Tab accessory tooltip for a single owner, e.g. `Size set by Maya's Mac · 118×38`.
    public var sizeSetBy: @Sendable (String, String) -> String
    /// Chip suffix when this view hides columns, e.g. `12 cols hidden`.
    public var hiddenColumns: @Sendable (Int) -> String

    /// Creates a string set.
    public init(
        thisMac: String,
        pair: @escaping @Sendable (String, String) -> String,
        possessiveDevice: @escaping @Sendable (String, String) -> String,
        deviceKind: @escaping @Sendable (TerminalDeviceKind) -> String,
        ownerFixed: String,
        ownerFitsEveryone: String,
        ownerLargest: String,
        ownerHeld: String,
        ownerShared: String,
        sizeSetBy: @escaping @Sendable (String, String) -> String,
        hiddenColumns: @escaping @Sendable (Int) -> String
    ) {
        self.thisMac = thisMac
        self.pair = pair
        self.possessiveDevice = possessiveDevice
        self.deviceKind = deviceKind
        self.ownerFixed = ownerFixed
        self.ownerFitsEveryone = ownerFitsEveryone
        self.ownerLargest = ownerLargest
        self.ownerHeld = ownerHeld
        self.ownerShared = ownerShared
        self.sizeSetBy = sizeSetBy
        self.hiddenColumns = hiddenColumns
    }

    /// English strings, for tests and previews.
    public static let english = TerminalSharingStrings(
        thisMac: "This Mac",
        pair: { "\($0) · \($1)" },
        possessiveDevice: { "\($0)'s \($1)" },
        deviceKind: { kind in
            switch kind {
            case .mac: "Mac"
            case .iphone: "iPhone"
            case .ipad: "iPad"
            case .tui: "Terminal client"
            case .browser: "Browser"
            case .unknown: "Device"
            }
        },
        ownerFixed: "Fixed",
        ownerFitsEveryone: "Fits everyone",
        ownerLargest: "Largest window",
        ownerHeld: "Held size",
        ownerShared: "Shared size",
        sizeSetBy: { "Size set by \($0) · \($1)" },
        hiddenColumns: { $0 == 1 ? "1 col hidden" : "\($0) cols hidden" }
    )
}

/// Labels and visibility rules for one terminal's sharing UI: the tab
/// accessory, the pane chip and the size panel all read from here so every
/// surface names people, devices and owners the same way.
public struct TerminalSharingPresentation: Sendable {
    /// Most avatars the tab accessory draws before `+N`.
    public static let maxTabAvatars = 3

    public let snapshot: TerminalSharingSnapshot
    public let strings: TerminalSharingStrings

    /// Creates a presentation.
    public init(snapshot: TerminalSharingSnapshot, strings: TerminalSharingStrings) {
        self.snapshot = snapshot
        self.strings = strings
    }

    public var state: TerminalSizingState { snapshot.state }

    /// `118 × 38`, for the panel header.
    public static func gridLabel(_ size: TerminalGridSize) -> String {
        "\(size.cols) × \(size.rows)"
    }

    /// `118×38`, for chips and tooltips.
    public static func compactGridLabel(_ size: TerminalGridSize) -> String {
        "\(size.cols)×\(size.rows)"
    }

    /// Up to two initials from the display name, else the device kind's first letter.
    public func initials(for participant: TerminalSizingParticipant) -> String {
        let words = (participant.displayName ?? "")
            .split(whereSeparator: { $0.isWhitespace || $0 == "@" || $0 == "." })
            .prefix(2)
        let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
        if !letters.isEmpty { return letters }
        return String(strings.deviceKind(participant.deviceKind).prefix(1)).uppercased()
    }

    /// The device, e.g. `Mac Studio`, or the device kind.
    public func deviceLabel(for participant: TerminalSizingParticipant) -> String {
        Self.trimmed(participant.deviceName) ?? strings.deviceKind(participant.deviceKind)
    }

    /// A panel row: `This Mac`, `Maya Ortiz · Mac Studio`, or the device alone.
    public func participantLabel(for participant: TerminalSizingParticipant) -> String {
        if participant.id == snapshot.selfParticipantID { return strings.thisMac }
        let device = deviceLabel(for: participant)
        guard let person = Self.trimmed(participant.displayName), person != device else { return device }
        return strings.pair(person, device)
    }

    /// A short owner name: `This Mac`, `Lawrence's Mac`, or the device alone.
    public func ownerName(for participant: TerminalSizingParticipant) -> String {
        if participant.id == snapshot.selfParticipantID { return strings.thisMac }
        guard let firstName = Self.trimmed(participant.displayName)?
            .split(whereSeparator: { $0.isWhitespace || $0 == "@" })
            .first.map(String.init) else {
            return deviceLabel(for: participant)
        }
        return strings.possessiveDevice(firstName, strings.deviceKind(participant.deviceKind))
    }

    /// Who or what sets the grid: an owner name, `Fixed`, `Fits everyone`…
    public var ownerLabel: String {
        if let owner = snapshot.owner { return ownerName(for: owner.participant) }
        switch state.reason {
        case .fixed: return strings.ownerFixed
        case .held: return strings.ownerHeld
        case .smallest: return strings.ownerFitsEveryone
        case .largest: return strings.ownerLargest
        case .latest, .priority, .priorityFallback: return strings.ownerShared
        }
    }

    /// The participant that sets the grid alone, if any.
    public var ownerID: String? { snapshot.owner?.id }

    // MARK: Tab accessory

    /// Whether the tab shows the avatar accessory: only while someone else is attached.
    public var showsTabAccessory: Bool { !snapshot.otherParticipantIDs.isEmpty }

    /// Participants for the tab accessory, owner first. Empty when the accessory is hidden.
    public var tabAccessoryParticipants: [TerminalSizingParticipantState] {
        guard showsTabAccessory else { return [] }
        let rows = state.participants
        guard let ownerID, let owner = rows.first(where: { $0.id == ownerID }) else { return rows }
        return [owner] + rows.filter { $0.id != ownerID }
    }

    /// `Size set by Maya's Mac · 118×38`, or `Fits everyone · 118×38`.
    public var tabAccessoryTooltip: String {
        let size = Self.compactGridLabel(state.size)
        if snapshot.owner != nil { return strings.sizeSetBy(ownerLabel, size) }
        return strings.pair(ownerLabel, size)
    }

    // MARK: Pane chip

    /// `118×38 · Lawrence's Mac`, plus ` · 12 cols hidden` when this view cuts columns.
    public func chipText(hiddenColumns: Int) -> String {
        let base = strings.pair(Self.compactGridLabel(state.size), ownerLabel)
        guard hiddenColumns > 0 else { return base }
        return strings.pair(base, strings.hiddenColumns(hiddenColumns))
    }

    // MARK: Panel

    /// Participant rows; in priority mode, in priority order.
    public var panelParticipants: [TerminalSizingParticipantState] {
        let rows = state.participants
        guard state.policy.mode == .priority else { return rows }
        let order = state.policy.priority
        return rows.enumerated().sorted { lhs, rhs in
            let l = order.firstIndex(of: lhs.element.priorityKey) ?? Int.max
            let r = order.firstIndex(of: rhs.element.priorityKey) ?? Int.max
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)
    }

    /// Whether the panel shows `Disconnect Others`.
    public var canDisconnectOthers: Bool { !snapshot.otherParticipantIDs.isEmpty }

    private static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

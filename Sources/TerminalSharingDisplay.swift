import AppKit
import CmuxFoundation
import CmuxTerminalSharing
import CmuxTerminalSizing
import SwiftUI
import Bonsplit

/// Localized labels, initials and owner colors for shared-terminal UI (tab
/// presence, pane bounds chip, size panel). One place so every surface names
/// people and devices the same way.
struct TerminalSharingDisplay {
    let snapshot: TerminalSharingSnapshot

    var state: TerminalSizingState { snapshot.state }

    /// `118 × 38`.
    static func gridLabel(_ size: TerminalGridSize) -> String {
        "\(size.cols) × \(size.rows)"
    }

    /// `118×38` for tight spaces (tab accessory).
    static func compactGridLabel(_ size: TerminalGridSize) -> String {
        "\(size.cols)×\(size.rows)"
    }

    static func colorHex(for participant: TerminalSizingParticipant) -> String {
        TerminalSizingParticipantColor(participant: participant).hex
    }

    static func nsColor(for participant: TerminalSizingParticipant) -> NSColor {
        NSColor(hex: colorHex(for: participant)) ?? .systemTeal
    }

    static func color(for participant: TerminalSizingParticipant) -> Color {
        Color(nsColor: nsColor(for: participant))
    }

    /// Up to two initials from the display name, else the device kind's first letter.
    static func initials(for participant: TerminalSizingParticipant) -> String {
        let words = (participant.displayName ?? "")
            .split(whereSeparator: { $0.isWhitespace || $0 == "@" || $0 == "." })
            .prefix(2)
        let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
        if !letters.isEmpty { return letters }
        return String(deviceKindLabel(participant.deviceKind).prefix(1)).uppercased()
    }

    static func deviceKindLabel(_ kind: TerminalDeviceKind) -> String {
        switch kind {
        case .mac: return String(localized: "terminalSharing.device.mac", defaultValue: "Mac")
        case .iphone: return String(localized: "terminalSharing.device.iphone", defaultValue: "iPhone")
        case .ipad: return String(localized: "terminalSharing.device.ipad", defaultValue: "iPad")
        case .tui: return String(localized: "terminalSharing.device.tui", defaultValue: "Terminal client")
        case .browser: return String(localized: "terminalSharing.device.browser", defaultValue: "Browser")
        case .unknown: return String(localized: "terminalSharing.device.unknown", defaultValue: "Device")
        }
    }

    /// The device, e.g. `Mac Studio` or `iPhone`.
    static func deviceLabel(for participant: TerminalSizingParticipant) -> String {
        if let name = participant.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return deviceKindLabel(participant.deviceKind)
    }

    /// The person, e.g. `Maya Ortiz`, or the device when no person is known.
    static func personLabel(for participant: TerminalSizingParticipant) -> String {
        if let name = participant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return deviceLabel(for: participant)
    }

    /// `Maya Ortiz · Mac Studio`, or `This Mac` for this view.
    func label(for participant: TerminalSizingParticipant) -> String {
        if participant.id == snapshot.selfParticipantID {
            return String(localized: "terminalSharing.participant.thisMac", defaultValue: "This Mac")
        }
        let person = Self.personLabel(for: participant)
        let device = Self.deviceLabel(for: participant)
        guard person != device else { return device }
        return String(
            format: String(localized: "terminalSharing.participant.personDevice", defaultValue: "%1$@ · %2$@"),
            person, device
        )
    }

    /// Who or what sets the grid, for the chip, HUD and panel header.
    var ownerLabel: String {
        if let owner = snapshot.owner { return label(for: owner.participant) }
        switch state.reason {
        case .fixed: return String(localized: "terminalSharing.owner.fixed", defaultValue: "Fixed size")
        case .held: return String(localized: "terminalSharing.owner.held", defaultValue: "Held size")
        case .smallest: return String(localized: "terminalSharing.owner.smallest", defaultValue: "Fits everyone")
        case .largest: return String(localized: "terminalSharing.owner.largest", defaultValue: "Largest window")
        case .latest, .priority, .priorityFallback:
            return String(localized: "terminalSharing.owner.shared", defaultValue: "Shared size")
        }
    }

    /// The owner color, or a neutral color without a single owner.
    var ownerNSColor: NSColor {
        snapshot.owner.map { Self.nsColor(for: $0.participant) } ?? .secondaryLabelColor
    }

    /// One sentence explaining the current size.
    var reasonSentence: String {
        switch state.reason {
        case .latest:
            return String(
                format: String(localized: "terminalSharing.reason.latest", defaultValue: "%@ typed or clicked most recently."),
                ownerLabel
            )
        case .priority:
            return String(
                format: String(localized: "terminalSharing.reason.priority", defaultValue: "%@ is highest in the priority list."),
                ownerLabel
            )
        case .priorityFallback:
            return String(localized: "terminalSharing.reason.priorityFallback", defaultValue: "Nobody in the priority list is attached, so the latest input sets the size.")
        case .smallest:
            return String(localized: "terminalSharing.reason.smallest", defaultValue: "Fits every window that counts.")
        case .largest:
            return String(localized: "terminalSharing.reason.largest", defaultValue: "Uses the largest window that counts.")
        case .fixed:
            return String(localized: "terminalSharing.reason.fixed", defaultValue: "The size is fixed.")
        case .held:
            return String(localized: "terminalSharing.reason.held", defaultValue: "Nobody counts toward the size, so the last size is held.")
        }
    }

    static func modeTitle(_ mode: TerminalSizingMode) -> String {
        switch mode {
        case .latest: return String(localized: "terminalSharing.mode.latest", defaultValue: "Latest")
        case .smallest: return String(localized: "terminalSharing.mode.smallest", defaultValue: "Smallest")
        case .largest: return String(localized: "terminalSharing.mode.largest", defaultValue: "Largest")
        case .priority: return String(localized: "terminalSharing.mode.priority", defaultValue: "Priority")
        case .fixed: return String(localized: "terminalSharing.mode.fixed", defaultValue: "Fixed")
        }
    }

    static func modeHelp(_ mode: TerminalSizingMode) -> String {
        switch mode {
        case .latest:
            return String(localized: "terminalSharing.modeHelp.latest", defaultValue: "The last person to type or click in this terminal sets the size.")
        case .smallest:
            return String(localized: "terminalSharing.modeHelp.smallest", defaultValue: "Fits everyone who counts. Big windows get empty space.")
        case .largest:
            return String(localized: "terminalSharing.modeHelp.largest", defaultValue: "Uses the biggest window. Smaller windows see a cut-off terminal.")
        case .priority:
            return String(localized: "terminalSharing.modeHelp.priority", defaultValue: "The highest attached participant in the list sets the size. Drag to reorder.")
        case .fixed:
            return String(localized: "terminalSharing.modeHelp.fixed", defaultValue: "The terminal keeps one size, whatever windows are attached.")
        }
    }

    /// The bonsplit tab accessory model, or `nil` when nobody else is attached.
    func tabPresence() -> TabPresence? {
        guard snapshot.isShared else { return nil }
        let owners = Set(state.owners)
        let participants = state.participants.map { row in
            TabPresence.Participant(
                id: row.id,
                initials: Self.initials(for: row.participant),
                colorHex: Self.colorHex(for: row.participant),
                isOwner: owners.count == 1 && owners.contains(row.id),
                accessibilityName: label(for: row.participant)
            )
        }
        let mode: TabPresence.SizeMode = TabPresence.SizeMode(rawValue: state.policy.mode.rawValue) ?? .latest
        let accessibility = String(
            format: String(
                localized: "terminalSharing.tab.accessibility",
                defaultValue: "Terminal size %1$@, set by %2$@. Show size panel."
            ),
            Self.gridLabel(state.size), ownerLabel
        )
        return TabPresence(
            participants: participants,
            gridLabel: Self.compactGridLabel(state.size),
            viewerMismatch: !snapshot.selfMatchesGrid,
            sizeMode: mode,
            countsFromThisDevice: snapshot.selfParticipant?.counts ?? true,
            canDisconnectOthers: !snapshot.otherParticipantIDs.isEmpty,
            accessibilityLabel: accessibility
        )
    }
}

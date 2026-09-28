import AppKit
import Bonsplit
import CmuxFoundation
import CmuxTerminalSharing
import CmuxTerminalSizing
import SwiftUI

/// Localized strings and owner colors for shared-terminal UI (tab accessory,
/// pane chip, size panel). The label rules live in
/// ``TerminalSharingPresentation``; this type supplies the app's catalog
/// strings and AppKit/SwiftUI colors.
struct TerminalSharingDisplay {
    let presentation: TerminalSharingPresentation

    init(snapshot: TerminalSharingSnapshot) {
        presentation = TerminalSharingPresentation(snapshot: snapshot, strings: Self.strings)
    }

    var snapshot: TerminalSharingSnapshot { presentation.snapshot }
    var state: TerminalSizingState { presentation.state }
    var ownerLabel: String { presentation.ownerLabel }

    static let strings = TerminalSharingStrings(
        thisMac: String(localized: "terminalSharing.participant.thisMac", defaultValue: "This Mac"),
        pair: { first, second in
            String(
                format: String(localized: "terminalSharing.participant.personDevice", defaultValue: "%1$@ · %2$@"),
                first, second
            )
        },
        possessiveDevice: { person, device in
            String(
                format: String(localized: "terminalSharing.owner.possessiveDevice", defaultValue: "%1$@'s %2$@"),
                person, device
            )
        },
        deviceKind: { TerminalSharingDisplay.deviceKindLabel($0) },
        ownerFixed: String(localized: "terminalSharing.owner.fixedShort", defaultValue: "Fixed"),
        ownerFitsEveryone: String(localized: "terminalSharing.owner.smallest", defaultValue: "Fits everyone"),
        ownerLargest: String(localized: "terminalSharing.owner.largest", defaultValue: "Largest window"),
        ownerHeld: String(localized: "terminalSharing.owner.held", defaultValue: "Held size"),
        ownerShared: String(localized: "terminalSharing.owner.shared", defaultValue: "Shared size"),
        sizeSetBy: { owner, size in
            String(
                format: String(localized: "terminalSharing.tab.tooltip", defaultValue: "Size set by %1$@ · %2$@"),
                owner, size
            )
        },
        hiddenColumns: { count in
            String(
                format: String(localized: "terminalSharing.chip.hiddenColumns", defaultValue: "%ld cols hidden"),
                count
            )
        }
    )

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

    static func modeTitle(_ mode: TerminalSizingMode) -> String {
        switch mode {
        case .latest: return String(localized: "terminalSharing.sizeMode.latest", defaultValue: "Follow Latest")
        case .smallest: return String(localized: "terminalSharing.sizeMode.smallest", defaultValue: "Fit Everyone")
        case .largest: return String(localized: "terminalSharing.sizeMode.largest", defaultValue: "Largest Window")
        case .priority: return String(localized: "terminalSharing.sizeMode.priority", defaultValue: "Priority")
        case .fixed: return String(localized: "terminalSharing.sizeMode.fixed", defaultValue: "Fixed")
        }
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

    /// The owner color, or a neutral color without a single owner.
    var ownerNSColor: NSColor {
        snapshot.owner.map { Self.nsColor(for: $0.participant) } ?? .secondaryLabelColor
    }

    /// The bonsplit tab model: nil unless this terminal needs sizing chrome.
    /// Participants are empty (no avatars) unless someone else is attached,
    /// so the context menu keeps its size actions while the accessory hides.
    func tabPresence() -> TabPresence? {
        guard snapshot.showsSizingChrome else { return nil }
        let ownerID = presentation.ownerID
        let participants = presentation.tabAccessoryParticipants.map { row in
            TabPresence.Participant(
                id: row.id,
                initials: presentation.initials(for: row.participant),
                colorHex: Self.colorHex(for: row.participant),
                isOwner: row.id == ownerID,
                accessibilityName: presentation.participantLabel(for: row.participant)
            )
        }
        return TabPresence(
            participants: participants,
            sizeMode: TabPresence.SizeMode(rawValue: state.policy.mode.rawValue) ?? .latest,
            canDisconnectOthers: presentation.canDisconnectOthers,
            accessibilityLabel: presentation.tabAccessoryTooltip
        )
    }
}

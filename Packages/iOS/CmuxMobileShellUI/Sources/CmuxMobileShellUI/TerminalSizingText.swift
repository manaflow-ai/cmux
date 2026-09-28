import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxTerminalSizing
import Foundation

/// Localized copy for the shared terminal sizing UI.
struct TerminalSizingText {
    private init() {}

    static func gridSize(_ size: TerminalGridSize) -> String {
        let cols = size.cols
        let rows = size.rows
        return L10n.string("mobile.terminal.sizing.gridSize", defaultValue: "\(cols) × \(rows)")
    }

    static func joined(_ first: String, _ second: String) -> String {
        L10n.string("mobile.terminal.sizing.joined", defaultValue: "\(first) · \(second)")
    }

    static func thisDevice(_ kind: TerminalDeviceKind) -> String {
        kind == .ipad
            ? L10n.string("mobile.terminal.sizing.thisIPad", defaultValue: "This iPad")
            : L10n.string("mobile.terminal.sizing.thisIPhone", defaultValue: "This iPhone")
    }

    static func someone() -> String {
        L10n.string("mobile.terminal.sizing.someone", defaultValue: "Someone")
    }

    static func unknownDevice() -> String {
        L10n.string("mobile.terminal.sizing.unknownDevice", defaultValue: "Unknown device")
    }

    static func deviceName(_ participant: TerminalSizingParticipant) -> String {
        participant.deviceName ?? unknownDevice()
    }

    /// "Maya's Mac Studio", or "This iPhone" for this phone.
    static func ownerLabel(_ participant: TerminalSizingParticipant, isSelf: Bool) -> String {
        if isSelf { return thisDevice(participant.deviceKind) }
        let device = deviceName(participant)
        guard let name = MobileTerminalSizingPresentation.givenName(participant.displayName) else {
            return device
        }
        return L10n.string("mobile.terminal.sizing.ownerDevice", defaultValue: "\(name)'s \(device)")
    }

    /// The corner chip: "118 × 38 · Maya's Mac Studio".
    static func chip(_ presentation: MobileTerminalSizingPresentation) -> String {
        let size = gridSize(presentation.grid)
        if let owner = presentation.owner {
            return joined(size, ownerLabel(owner.participant, isSelf: presentation.ownerIsSelf))
        }
        return joined(size, modeName(presentation.policy.mode))
    }

    static func hiddenColumns(_ count: Int) -> String {
        L10n.string("mobile.terminal.sizing.hiddenColumns", defaultValue: "+\(count) cols")
    }

    static func hiddenRows(_ count: Int) -> String {
        L10n.string("mobile.terminal.sizing.hiddenRows", defaultValue: "+\(count) rows")
    }

    static func cutAccessibilityLabel(_ pill: String) -> String {
        L10n.string("mobile.terminal.sizing.cut.accessibility", defaultValue: "\(pill) not visible on this screen")
    }

    static func chipAccessibilityHint() -> String {
        L10n.string("mobile.terminal.sizing.chip.accessibilityHint", defaultValue: "Opens terminal size settings")
    }

    static func modeName(_ mode: TerminalSizingMode) -> String {
        switch mode {
        case .latest: L10n.string("mobile.terminal.sizing.mode.latest", defaultValue: "Latest")
        case .smallest: L10n.string("mobile.terminal.sizing.mode.smallest", defaultValue: "Smallest")
        case .largest: L10n.string("mobile.terminal.sizing.mode.largest", defaultValue: "Largest")
        case .priority: L10n.string("mobile.terminal.sizing.mode.priority", defaultValue: "Priority")
        case .fixed: L10n.string("mobile.terminal.sizing.mode.fixed", defaultValue: "Fixed")
        }
    }

    static func reason(_ reason: TerminalSizingReason) -> String {
        switch reason {
        case .latest:
            L10n.string("mobile.terminal.sizing.reason.latest", defaultValue: "Set by the most recently active client.")
        case .smallest:
            L10n.string("mobile.terminal.sizing.reason.smallest", defaultValue: "Fits the smallest client.")
        case .largest:
            L10n.string("mobile.terminal.sizing.reason.largest", defaultValue: "Fits the largest client.")
        case .priority:
            L10n.string("mobile.terminal.sizing.reason.priority", defaultValue: "Set by the highest-priority client.")
        case .priorityFallback:
            L10n.string(
                "mobile.terminal.sizing.reason.priorityFallback",
                defaultValue: "No priority client is attached, so the most recently active client sets the size."
            )
        case .fixed:
            L10n.string("mobile.terminal.sizing.reason.fixed", defaultValue: "Fixed size.")
        case .held:
            L10n.string(
                "mobile.terminal.sizing.reason.held",
                defaultValue: "No client sets the size, so it keeps its last size."
            )
        }
    }

    static func reconnecting() -> String {
        L10n.string("mobile.terminal.sizing.reconnecting", defaultValue: "Reconnecting…")
    }

    // MARK: Detached card

    static func detachedTitle(tab: String) -> String {
        L10n.string("mobile.terminal.detached.title", defaultValue: "Detached from \(tab)")
    }

    static func detachedMessage(
        reason: TerminalDetachReason,
        at: Date?,
        deviceKind: TerminalDeviceKind
    ) -> String {
        switch reason {
        case let .disconnectedBy(actor):
            let name = actor?.displayName ?? someone()
            let device = actor?.deviceName ?? unknownDevice()
            let time = (at ?? Date()).formatted(date: .omitted, time: .shortened)
            if deviceKind == .ipad {
                return L10n.string(
                    "mobile.terminal.detached.message.ipad",
                    defaultValue: "\(name) (\(device)) disconnected this iPad at \(time). The terminal is still running."
                )
            }
            return L10n.string(
                "mobile.terminal.detached.message.iphone",
                defaultValue: "\(name) (\(device)) disconnected this iPhone at \(time). The terminal is still running."
            )
        case .hostShutdown:
            return L10n.string(
                "mobile.terminal.detached.hostShutdown",
                defaultValue: "The Mac stopped sharing this terminal."
            )
        case .superseded:
            return L10n.string(
                "mobile.terminal.detached.superseded",
                defaultValue: "Another connection from this device replaced this one."
            )
        case .network:
            return reconnecting()
        }
    }

    static func reattach() -> String {
        L10n.string("mobile.terminal.detached.reattach", defaultValue: "Reattach")
    }

    static func reattachAsViewer() -> String {
        L10n.string("mobile.terminal.detached.reattachAsViewer", defaultValue: "Reattach as viewer (doesn't resize)")
    }

    static func reattachFailed() -> String {
        L10n.string("mobile.terminal.detached.reattachFailed", defaultValue: "Couldn't reattach. Try again.")
    }

    // MARK: Size sheet

    static func sheetTitle() -> String {
        L10n.string("mobile.terminal.sizing.sheet.title", defaultValue: "Terminal Size")
    }

    static func currentSize() -> String {
        L10n.string("mobile.terminal.sizing.sheet.current", defaultValue: "Current Size")
    }

    static func modePicker() -> String {
        L10n.string("mobile.terminal.sizing.sheet.mode", defaultValue: "Sizing")
    }

    static func participants() -> String {
        L10n.string("mobile.terminal.sizing.sheet.participants", defaultValue: "Connected")
    }

    static func badgeSetsSize() -> String {
        L10n.string("mobile.terminal.sizing.badge.setsSize", defaultValue: "Sets size")
    }

    static func badgeViewer() -> String {
        L10n.string("mobile.terminal.sizing.badge.viewer", defaultValue: "Viewer")
    }

    static func badgeDetached() -> String {
        L10n.string("mobile.terminal.sizing.badge.detached", defaultValue: "Detached")
    }

    static func badgeYou() -> String {
        L10n.string("mobile.terminal.sizing.badge.you", defaultValue: "You")
    }

    static func countsToggle() -> String {
        L10n.string("mobile.terminal.sizing.sheet.counts", defaultValue: "Counts toward size")
    }

    static func disconnect() -> String {
        L10n.string("mobile.terminal.sizing.sheet.disconnect", defaultValue: "Disconnect")
    }

    static func disconnectAccessibilityLabel(_ who: String) -> String {
        L10n.string("mobile.terminal.sizing.sheet.disconnect.accessibility", defaultValue: "Disconnect \(who)")
    }

    static func disconnectOthers() -> String {
        L10n.string("mobile.terminal.sizing.sheet.disconnectOthers", defaultValue: "Disconnect Other Clients")
    }

    static func disconnectOthersConfirm() -> String {
        L10n.string(
            "mobile.terminal.sizing.sheet.disconnectOthers.confirm",
            defaultValue: "Disconnect every other client from this terminal? They can reattach later."
        )
    }

    static func cancel() -> String {
        L10n.string("mobile.terminal.sizing.sheet.cancel", defaultValue: "Cancel")
    }

    static func done() -> String {
        L10n.string("mobile.terminal.sizing.sheet.done", defaultValue: "Done")
    }

    static func priorityHint() -> String {
        L10n.string(
            "mobile.terminal.sizing.sheet.priorityHint",
            defaultValue: "Drag to set which client sizes the terminal first."
        )
    }

    static func fixedColumns(_ count: Int) -> String {
        L10n.string("mobile.terminal.sizing.sheet.fixedColumns", defaultValue: "Columns: \(count)")
    }

    static func fixedRows(_ count: Int) -> String {
        L10n.string("mobile.terminal.sizing.sheet.fixedRows", defaultValue: "Rows: \(count)")
    }

    static func changeFailed() -> String {
        L10n.string("mobile.terminal.sizing.sheet.failed", defaultValue: "The Mac didn't accept the change.")
    }
}

import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxTerminalSizing
import Foundation

/// Localized copy for the shared terminal sizing UI.
struct TerminalSizingText {
    private init() {}

    /// "118 × 38", for the sheet header.
    static func gridSize(_ size: TerminalGridSize) -> String {
        let cols = size.cols
        let rows = size.rows
        return L10n.string("mobile.terminal.sizing.gridSize", defaultValue: "\(cols) × \(rows)")
    }

    /// "118×38", for the chip.
    static func gridSizeCompact(_ size: TerminalGridSize) -> String {
        let cols = size.cols
        let rows = size.rows
        return L10n.string("mobile.terminal.sizing.gridSizeCompact", defaultValue: "\(cols)×\(rows)")
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

    /// "Maya's Mac Studio", "This iPhone", or the mode when no one owns the size.
    static func owner(_ label: MobileTerminalSizingOwnerLabel) -> String {
        switch label {
        case let .thisDevice(kind):
            return thisDevice(kind)
        case let .person(name, device?):
            return L10n.string("mobile.terminal.sizing.ownerDevice", defaultValue: "\(name)'s \(device)")
        case let .person(name, nil):
            return name
        case let .device(device):
            return device
        case .unnamed:
            return someone()
        case let .policy(mode):
            return modeName(mode)
        }
    }

    /// "scaled", appended when the grid is drawn smaller to fit this phone.
    static func scaled() -> String {
        L10n.string("mobile.terminal.sizing.scaled", defaultValue: "scaled")
    }

    /// The chip: "118×38 · Maya's Mac Studio", plus " · scaled" when this
    /// phone is narrower than the grid and shows it scaled to fit.
    static func chip(_ presentation: MobileTerminalSizingPresentation) -> String {
        let base = joined(gridSizeCompact(presentation.grid), owner(presentation.ownerLabel))
        guard presentation.isScaledToFit else { return base }
        return joined(base, scaled())
    }

    static func chipAccessibilityLabel(_ presentation: MobileTerminalSizingPresentation) -> String {
        let cols = presentation.grid.cols
        let rows = presentation.grid.rows
        let who = owner(presentation.ownerLabel)
        let base = L10n.string(
            "mobile.terminal.sizing.chip.accessibilityLabel",
            defaultValue: "Terminal size \(cols) by \(rows), set by \(who)"
        )
        guard presentation.isScaledToFit else { return base }
        let scaledText = L10n.string(
            "mobile.terminal.sizing.scaled.accessibility",
            defaultValue: "Scaled down to fit this screen"
        )
        return "\(base). \(scaledText)"
    }

    static func chipAccessibilityHint() -> String {
        L10n.string("mobile.terminal.sizing.chip.accessibilityHint", defaultValue: "Opens terminal size settings")
    }

    static func modeName(_ mode: TerminalSizingMode) -> String {
        switch mode {
        case .latest: L10n.string("mobile.terminal.sizing.mode.latest", defaultValue: "Follow latest")
        case .smallest: L10n.string("mobile.terminal.sizing.mode.smallest", defaultValue: "Fit everyone")
        case .largest: L10n.string("mobile.terminal.sizing.mode.largest", defaultValue: "Largest window")
        case .priority: L10n.string("mobile.terminal.sizing.mode.priority", defaultValue: "Priority")
        case .fixed: L10n.string("mobile.terminal.sizing.mode.fixed", defaultValue: "Fixed")
        }
    }

    static func reconnecting() -> String {
        L10n.string("mobile.terminal.sizing.reconnecting", defaultValue: "Reconnecting…")
    }

    // MARK: Detached card

    static func detachedTitle() -> String {
        L10n.string("mobile.terminal.detached.heading", defaultValue: "Detached")
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
                    defaultValue: "\(name) (\(device)) disconnected this iPad at \(time)."
                )
            }
            return L10n.string(
                "mobile.terminal.detached.message.iphone",
                defaultValue: "\(name) (\(device)) disconnected this iPhone at \(time)."
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
        L10n.string("mobile.terminal.detached.reattachAsViewer", defaultValue: "Reattach as viewer")
    }

    static func reattachFailed() -> String {
        L10n.string("mobile.terminal.detached.reattachFailed", defaultValue: "Couldn't reattach. Try again.")
    }

    // MARK: Size sheet

    static func sizePicker() -> String {
        L10n.string("mobile.terminal.sizing.sheet.mode", defaultValue: "Size")
    }

    static func fixedSize() -> String {
        L10n.string("mobile.terminal.sizing.sheet.fixedSize", defaultValue: "Columns × Rows")
    }

    static func columns() -> String {
        L10n.string("mobile.terminal.sizing.sheet.columns", defaultValue: "Columns")
    }

    static func rows() -> String {
        L10n.string("mobile.terminal.sizing.sheet.rows", defaultValue: "Rows")
    }

    static func participants() -> String {
        L10n.string("mobile.terminal.sizing.sheet.participants", defaultValue: "Connected")
    }

    static func setsSize() -> String {
        L10n.string("mobile.terminal.sizing.badge.setsSize", defaultValue: "Sets size")
    }

    static func notCounted() -> String {
        L10n.string("mobile.terminal.sizing.badge.notCounted", defaultValue: "Not counted")
    }

    /// Trailing text of a sheet row, or `nil` for a counted non-owner.
    static func rowStatus(_ status: MobileTerminalSizingRowStatus) -> String? {
        switch status {
        case .setsSize: setsSize()
        case .notCounted: notCounted()
        case .counted: nil
        }
    }

    /// "Maya · Mac Studio", or "Maya · This iPhone" for this phone.
    static func participantTitle(_ participant: TerminalSizingParticipant, isSelf: Bool) -> String {
        let given = MobileTerminalSizingPresentation.givenName(participant.displayName)
        let device = isSelf
            ? thisDevice(participant.deviceKind)
            : participant.deviceName.flatMap { $0.isEmpty ? nil : $0 }
        // "Maya's MacBook Pro" already names its owner.
        let deviceNamesOwner = !isSelf && given.map { device?.localizedCaseInsensitiveContains($0) ?? false } == true
        let name = given == nil || deviceNamesOwner ? nil : participant.displayName
        switch (name, device) {
        case let (name?, device?): return joined(name, device)
        case let (name?, nil): return name
        case let (nil, device?): return device
        case (nil, nil): return someone()
        }
    }

    static func countsToggle() -> String {
        L10n.string("mobile.terminal.sizing.sheet.counts", defaultValue: "Counts toward size")
    }

    static func disconnect() -> String {
        L10n.string("mobile.terminal.sizing.sheet.disconnect", defaultValue: "Disconnect")
    }

    static func disconnectOthers() -> String {
        L10n.string("mobile.terminal.sizing.sheet.disconnectOthers", defaultValue: "Disconnect Others")
    }

    static func disconnectOthersConfirm() -> String {
        L10n.string(
            "mobile.terminal.sizing.sheet.disconnectOthers.confirm",
            defaultValue: "Disconnect every other client from this terminal? They can reattach later."
        )
    }

    static func done() -> String {
        L10n.string("mobile.terminal.sizing.sheet.done", defaultValue: "Done")
    }

    static func changeFailed() -> String {
        L10n.string("mobile.terminal.sizing.sheet.failed", defaultValue: "The Mac didn't accept the change.")
    }
}

import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextDevices

/// Screen Sharing ▸ in the new tab ⌄ menu (and the pane and tab menus' Screen Sharing row): one row per
/// machine this Mac can view, so one click opens that machine's screen, then All Devices… (the Screen
/// Sharing page). Leo, 2026-11-18 (c-b99282b1ed): "you should be able to click the chevron next to teh +
/// of new tab and just go there", "i should be able to see into any connected mac or linux machine".
/// Which machines, their order and why one cannot be viewed are Rust's (``ScreenPicker``); this draws them.
/// A machine that cannot be viewed names why ("Sharing off", "Not allowed", "Offline") and, where its
/// host can fix it, opens the one step to do there (``MacScreenHostSetupGuide``).
@MainActor
struct MacScreenPickerMenu {
    let pages: MacScreenPages
    let registry: ActionRegistry

    static let action: ActionID = "macScreen.open"

    /// The submenu for a Screen Sharing row on `target`; nil (the plain row, the Screen Sharing page) while
    /// signed out, while no machine is listed, or in a menu scoped to another machine. This Mac's own panes
    /// pass their daemon's id, `local` (``DaemonService/isLocal``), so `local` counts as this Mac.
    func menu(target: ActionTargetRef?, machineID: String?) -> NSMenu? {
        guard Self.isThisMac(machineID), let hub = pages.hub else { return nil }
        let connected = hub.connection == .connected
        let machines = MacScreenHomeSnapshot.listed(hub.otherDevices).map { device in
            ScreenPicker.Machine(device, onlineKnown: connected,
                                 allowsRequests: MacScreenAccess(hub.scope(host: device.id, viewer: hub.identity.id)).allowsRequests)
        }
        let rows = ScreenPicker.make(machines).rows
        guard !rows.isEmpty else { return nil }
        let thisMac = MacScreenHostSetupGuide.ThisMac(id: hub.identity.id, name: hub.thisDevice?.name ?? hub.deviceName)
        let menu = NSMenu(title: registry.title(for: Self.action) ?? "")
        rows.map { item(for: $0, target: target, thisMac: thisMac) }.forEach(menu.addItem)
        menu.addItem(.separator())
        if let all = registry.makeArgumentMenuItem(for: Self.action, target: target, title: Self.allDevices) {
            all.image = nil
            all.setAccessibilityIdentifier("macScreen.picker.allDevices")
            menu.addItem(all)
        }
        return menu
    }

    private func item(for row: ScreenPicker.Row, target: ActionTargetRef?, thisMac: MacScreenHostSetupGuide.ThisMac) -> NSMenuItem {
        let image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil)
        if row.opens, let item = registry.makeArgumentMenuItem(for: Self.action, target: target,
                                                               arguments: ["device": .string(row.id)], title: row.name) {
            item.image = image
            item.setAccessibilityIdentifier("macScreen.picker.\(row.name)")
            return item
        }
        let reason = Self.reason(row.state)
        let item = NSMenuItem(title: row.name, action: nil, keyEquivalent: "")
        item.image = image
        item.setAccessibilityIdentifier("macScreen.picker.\(row.name)")
        if #available(macOS 14.4, *) {
            item.subtitle = reason
        } else {
            item.title = "\(row.name) — \(reason)"
        }
        if let fix = row.fix {
            // Enabled: a click opens the one step its host takes, not a dead grey row.
            let guide = MacScreenHostSetupGuide(host: row.name, fix: fix, thisMac: thisMac)
            let runner = MacScreenMenuRunner { guide.present(in: NSApp.keyWindow ?? NSApp.mainWindow) }
            item.target = runner
            item.action = #selector(MacScreenMenuRunner.run)
            item.representedObject = runner
            item.toolTip = guide.line
        } else {
            item.isEnabled = false
        }
        return item
    }

    static func reason(_ state: ScreenPicker.State) -> String {
        switch state {
        case .view: ""
        case .sharingOff: L.t("macScreen.home.sharingOff", "Sharing off")
        case .notAllowed: L.t("macScreen.home.blockedShort", "Not allowed")
        case .offline: L.t("macScreen.picker.offline", "Offline")
        }
    }

    /// Whether a menu scoped to `machineID` is this Mac's: no machine, or the local daemon's `local`.
    static func isThisMac(_ machineID: String?) -> Bool {
        machineID == nil || machineID == "local"
    }

    static var allDevices: String { L.t("macScreen.picker.allDevices", "All Devices…") }
}

/// A menu row's click, for a row that runs no action (``NSMenuItem/target`` is weak: the item keeps it).
@MainActor
final class MacScreenMenuRunner: NSObject {
    private let perform: () -> Void

    init(_ perform: @escaping () -> Void) {
        self.perform = perform
    }

    @objc func run() { perform() }
}

/// The one step a host takes so this Mac can view it, for a machine whose row says "Sharing off" or
/// "Not allowed" (Leo, 2026-11-18, c-2e1353ee11: "the whole \"allow blah blah\" is so annoying too").
/// Sharing off: Share This Mac there runs the whole setup as one guided step (the switch, Screen
/// Recording, Accessibility; ``CmuxRemoteSharingSetup``), and `cmux remote-host share on` there starts it.
/// Not allowed: its Settings › Devices lets this Mac in, and `cmux remote-host access` there does it.
/// It cannot run on the host from here: this Mac's signed approval has no carrier to it yet
/// (`share.needs_same_account_control`, cmux-tui `remote_host/share_approval.rs`).
@MainActor
struct MacScreenHostSetupGuide {
    struct ThisMac: Equatable {
        var id: String
        var name: String
    }

    let host: String
    let fix: ScreenPicker.Fix
    let thisMac: ThisMac

    var title: String {
        switch fix {
        case .shareThisMac: String(format: L.t("macScreen.guide.share.title", "Turn On Screen Sharing on %@"), host)
        case .deviceAccess: String(format: L.t("macScreen.guide.access.title", "Let %@ In on %@"), thisMac.name, host)
        }
    }

    /// The step, in one line (the dialog's first line and the row's tooltip).
    var line: String {
        switch fix {
        case .shareThisMac:
            String(format: L.t("macScreen.guide.share.body", "On %@, turn on Share This Mac. One guided step turns sharing on and asks for Screen Recording and Accessibility."), host)
        case .deviceAccess:
            String(format: L.t("macScreen.guide.access.body", "On %@, open Settings › Devices and set %@ to View Only or Full Control."), host, thisMac.name)
        }
    }

    /// The command that takes the step on the host, run there (by the person or an agent).
    var command: String {
        switch fix {
        case .shareThisMac: "cmux remote-host share on"
        case .deviceAccess: "cmux remote-host access \(thisMac.id) full"
        }
    }

    var spec: CmuxDialogSpec {
        CmuxDialogSpec(title: title,
                       lines: [line, String(format: L.t("macScreen.guide.command", "Or run this on %@: %@"), host, command)],
                       buttons: [.cancel(), CmuxDialogButton(id: "copy", title: L.t("macScreen.guide.copy", "Copy Command"), role: .default)],
                       identifier: "cmux.dialog.macScreen.hostSetup")
    }

    func present(in window: NSWindow?) {
        let command = command
        CmuxDialogCenter.shared.present(spec, in: window.map(CmuxDialogScope.window) ?? .app) { answer in
            guard answer.button == "copy" else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
    }
}

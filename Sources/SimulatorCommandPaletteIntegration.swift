import AppKit
import CmuxCommandPalette
import CmuxSimulator
import CmuxSettings
import Foundation

extension CommandPaletteCommandContribution {
    static var newSimulatorPane: Self {
        Self(
            commandId: "palette.newSimulatorPane",
            title: { _ in
                String(localized: "command.newSimulatorPane.title", defaultValue: "New Simulator Pane")
            },
            subtitle: { _ in
                String(localized: "command.newSimulatorPane.subtitle", defaultValue: "iPhone and iPad")
            },
            keywords: ["new", "simulator", "iphone", "ipad", "ios", "pane"]
        )
    }
}

extension CommandPaletteHandlerRegistry {
    @MainActor
    mutating func registerNewSimulatorPane(tabManager: TabManager, windowId: UUID) {
        register(commandId: "palette.newSimulatorPane") {
            guard CmuxFeatureFlags.shared.isSimulatorEnabled,
                  let appDelegate = AppDelegate.shared,
                  appDelegate.executeConfiguredCmuxAction(
                    id: CmuxSurfaceTabBarBuiltInAction.newSimulator.configID,
                    tabManager: tabManager,
                    preferredWindow: appDelegate.mainWindow(for: windowId)
                  ) else {
                NSSound.beep()
                return
            }
        }
    }
}

extension KeyboardShortcutSettings.Action {
    static let simulatorActions: [Self] = [
        .simulatorHome,
        .simulatorRotateLeft,
        .simulatorRotateRight,
        .simulatorToggleAppearance,
        .simulatorToggleSoftwareKeyboard,
    ]

    var simulatorLabel: String {
        switch self {
        case .simulatorHome:
            String(localized: "shortcut.simulatorHome.label", defaultValue: "Simulator: Home")
        case .simulatorRotateLeft:
            String(localized: "shortcut.simulatorRotateLeft.label", defaultValue: "Simulator: Rotate Left")
        case .simulatorRotateRight:
            String(localized: "shortcut.simulatorRotateRight.label", defaultValue: "Simulator: Rotate Right")
        case .simulatorToggleAppearance:
            String(localized: "shortcut.simulatorToggleAppearance.label", defaultValue: "Simulator: Toggle Appearance")
        case .simulatorToggleSoftwareKeyboard:
            String(localized: "shortcut.simulatorToggleSoftwareKeyboard.label", defaultValue: "Simulator: Toggle Software Keyboard")
        default:
            preconditionFailure("Not a Simulator shortcut action")
        }
    }

    var simulatorDefaultShortcut: StoredShortcut {
        switch self {
        case .simulatorHome:
            StoredShortcut(key: "h", command: true, shift: true, option: false, control: false)
        case .simulatorRotateLeft:
            StoredShortcut(key: "←", command: true, shift: false, option: false, control: false)
        case .simulatorRotateRight:
            StoredShortcut(key: "→", command: true, shift: false, option: false, control: false)
        case .simulatorToggleAppearance:
            StoredShortcut(key: "a", command: true, shift: true, option: false, control: false)
        case .simulatorToggleSoftwareKeyboard:
            StoredShortcut(key: "k", command: true, shift: false, option: false, control: false)
        default:
            preconditionFailure("Not a Simulator shortcut action")
        }
    }
}

extension AppDelegate {
    func handleSimulatorShortcut(_ event: NSEvent) -> Bool {
        guard CmuxFeatureFlags.shared.isSimulatorEnabled else { return false }
        let context = shortcutEventFocusContext(event).shortcutContext
        guard context.bool(ShortcutContextKnownKey.simulatorFocus.rawValue),
              let manager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager,
              let workspace = manager.selectedWorkspace,
              let window = event.window,
              let responder = window.firstResponder,
              let panel = workspace.panels.values.compactMap({ $0 as? SimulatorPanel }).first(where: {
                  $0.ownedFocusIntent(for: responder, in: window) != nil
              }),
              workspace.focusedPanelId == panel.id,
              let action = KeyboardShortcutSettings.Action.simulatorActions.first(where: {
                  matchConfiguredShortcut(event: event, action: $0)
              }) else {
            return false
        }
        guard !event.isARepeat else { return true }

        switch action {
        case .simulatorHome:
            panel.coordinator.press(.home)
        case .simulatorRotateLeft:
            panel.coordinator.rotateLeft()
        case .simulatorRotateRight:
            panel.coordinator.rotateRight()
        case .simulatorToggleAppearance:
            let coordinator = panel.coordinator
            Task { @MainActor [weak coordinator] in await coordinator?.toggleAppearance() }
        case .simulatorToggleSoftwareKeyboard:
            panel.coordinator.toggleSoftwareKeyboard()
        default:
            return false
        }
        return true
    }
}

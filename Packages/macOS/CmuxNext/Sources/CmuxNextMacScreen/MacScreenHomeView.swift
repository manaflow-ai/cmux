public import AppKit
import CmuxNextDesign
public import CmuxNextDevices
public import SwiftUI

/// What the home page asks of its owner.
public struct MacScreenHomeActions {
    /// Show one of the user's devices in this tab, asking the hub for the scope (nil: the Connect card).
    public var openDevice: (String, SessionScope?) -> Void = { _, _ in }
    /// Show one of the user's devices in a new tab.
    public var openDeviceInNewTab: (String, SessionScope?) -> Void = { _, _ in }

    public init() {}
}

/// Mac Screen's home page: the user's devices from the device hub, Allow
/// Mac Screen on This Mac, and the keyboard setting. Mac Screen works only
/// through the device hub (pairing links are gone): without one, or signed
/// out, the page says how to set it up. Drawn in the tab's theme
/// (`MacScreenColors`, `MacScreenType`).
public struct MacScreenHomeView: View {
    let host: MacScreenShareHost
    let actions: MacScreenHomeActions
    let systemShortcuts: MacScreenSystemShortcuts?
    let devices: MacScreenHomeDevices?
    @Environment(\.macScreenColors) private var colors

    public init(host: MacScreenShareHost, actions: MacScreenHomeActions, systemShortcuts: MacScreenSystemShortcuts? = nil,
                devices: MacScreenHomeDevices? = nil) {
        self.host = host
        self.actions = actions
        self.systemShortcuts = systemShortcuts
        self.devices = devices
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let devices { MacScreenHomeDeviceSections(devices: devices, host: host, actions: actions) }
                if let systemShortcuts { keyboardSection(systemShortcuts) }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
        .font(MacScreenType.body)
        .foregroundStyle(colors.primary)
        .tint(colors.focus)
        .background(colors.page)
        .onAppear {
            host.refreshPermissions()
            systemShortcuts?.refreshAccessibility()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L.t("macScreen.home.title", "Mac Screen"), systemImage: "display")
                .font(MacScreenType.title)
            Text(L.t("macScreen.home.subtitle", "See and control your other Macs from a cmux tab."))
                .font(MacScreenType.subtitle)
                .foregroundStyle(colors.secondary)
        }
    }

    // MARK: Keyboard

    /// Send System Shortcuts to the Remote Mac, and the Accessibility it needs.
    private func keyboardSection(_ shortcuts: MacScreenSystemShortcuts) -> some View {
        MacScreenSection(title: L.t("macScreen.home.keyboardTitle", "Keyboard")) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(get: { shortcuts.enabled }, set: { shortcuts.setEnabled($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("macScreen.home.systemShortcuts", "Send system shortcuts to the remote Mac"))
                        Text(L.t("macScreen.home.systemShortcutsDetail", "While a Mac’s screen has the keyboard, ⌘Tab, ⌘Space, Mission Control, Spaces, screenshots and ⌘Q, ⌘W, ⌘H, ⌘M go to that Mac. ⌃⌥⎋ still releases the keyboard."))
                            .font(MacScreenType.caption).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .tint(colors.focus)
                .accessibilityIdentifier("macScreen.home.systemShortcuts")
                if shortcuts.needsAccessibility {
                    MacScreenDivider()
                    MacScreenPermissionRow(title: L.t("macScreen.home.accessibility", "Accessibility"),
                                           detail: L.t("macScreen.home.systemShortcutsAccessibility", "Lets cmux take system shortcuts before macOS does, to send them to the other Mac."),
                                           granted: false, action: L.t("macScreen.home.allowAccessibility", "Allow Accessibility")) {
                        shortcuts.requestAccessibility()
                    }
                    .accessibilityIdentifier("macScreen.home.systemShortcutsAccessibility")
                }
            }
            .padding(14)
        }
    }
}

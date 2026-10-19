import CmuxNextDesign
public import CmuxNextDevices
import Foundation
import SwiftUI

/// What the home page reads of the device hub: the hub (while signed in),
/// this Mac as a host, and whether the build has a hub at all.
@MainActor
public struct MacScreenHomeDevices {
    let box: MacScreenHubBox
    let hubHost: MacScreenHubHost

    init(pages: MacScreenPages) {
        box = pages.hubBox
        hubHost = pages.hubHost
    }
}

/// The home page's device hub sections: Your Devices (the user's other
/// devices that share Mac Screen, online state and this Mac's access to
/// each, Connect with View Only or Full Control, Change Access) and Allow
/// Mac Screen on This Mac (the switch, its permissions and who is
/// connected).
struct MacScreenHomeDeviceSections: View {
    let devices: MacScreenHomeDevices
    let host: MacScreenShareHost
    let actions: MacScreenHomeActions
    @Environment(\.macScreenColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            yourDevices
            if let hub = devices.box.hub, hub.thisDevice != nil { sharing(hub) }
        }
    }

    // MARK: Your Devices

    private var yourDevices: some View {
        MacScreenSection(title: L.t("macScreen.home.yourDevices", "Your Devices")) {
            if let hub = devices.box.hub {
                deviceList(hub)
            } else {
                note(devices.box.configured
                     ? L.t("macScreen.home.devicesSignIn", "Sign in to cmux to see your other Macs here.")
                     : L.t("macScreen.home.devicesUnavailable", "Your other Macs show here once this build has a device hub."))
            }
        }
    }

    @ViewBuilder
    private func deviceList(_ hub: DeviceHub) -> some View {
        let shared = hub.otherDevices.filter(\.macScreenShared)
        if shared.isEmpty {
            note(hub.status == .ready || hub.status == .idle
                 ? L.t("macScreen.home.noSharedDevices", "None of your other devices share Mac Screen. On the Mac you want to see, turn on Allow Mac Screen on this Mac.")
                 : L.t("macScreen.home.devicesLoading", "Loading your devices…"))
        } else {
            VStack(spacing: 0) {
                ForEach(shared) { device in
                    deviceRow(device, hub: hub)
                    if device.id != shared.last?.id, colors.borders { colors.separator.frame(height: 1).padding(.leading, 50) }
                }
            }
            // This Mac's access to each host is that host's permission list: read it for the hosts shown.
            .task(id: shared.map(\.id)) {
                for device in shared { await hub.refreshPermissions(host: device.id) }
            }
        }
    }

    private func deviceRow(_ device: HubDevice, hub: DeviceHub) -> some View {
        let access = hub.scope(host: device.id, viewer: hub.identity.id)
        return HStack(spacing: 12) {
            Image(systemName: device.platform == .ios ? "iphone" : "desktopcomputer")
                .font(MacScreenType.glyph).foregroundStyle(colors.secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(MacScreenType.emphasized)
                HStack(spacing: 6) {
                    Circle().fill(device.online ? colors.success : colors.tertiary).frame(width: 7, height: 7)
                    Text(device.online ? L.t("macScreen.home.online", "Online") : L.t("macScreen.home.offline", "Offline"))
                    Text("·")
                    Text(String(format: L.t("macScreen.home.access", "Your access: %@"), MacScreenAccess(access).title))
                }
                .font(MacScreenType.caption).foregroundStyle(colors.secondary)
            }
            Spacer()
            if access == .none {
                Menu {
                    Button(L.t("macScreen.hub.view", "View Only")) { askForAccess(device, scope: .view, hub: hub) }
                    Button(L.t("macScreen.hub.control", "Full Control")) { askForAccess(device, scope: .full, hub: hub) }
                } label: {
                    Text(L.t("macScreen.home.askForAccess", "Ask for Access")).font(MacScreenType.body)
                }
                .macScreenMenu(colors.primary)
                .themedHelp(L.t("macScreen.home.askForAccessHelp", "Sets this Mac’s access to Ask, then asks that Mac; its prompt can allow this Mac from now on."))
                .accessibilityIdentifier("macScreen.home.askForAccess.\(device.name)")
            } else {
                Button(L.t("macScreen.hub.view", "View Only")) { actions.openDevice(device.id, .view) }
                    .buttonStyle(MacScreenButtonStyle())
                    .accessibilityIdentifier("macScreen.home.view.\(device.name)")
                Button(L.t("macScreen.hub.control", "Full Control")) { actions.openDevice(device.id, .full) }
                    .buttonStyle(MacScreenButtonStyle(role: .primary))
                    .accessibilityIdentifier("macScreen.home.control.\(device.name)")
            }
            Menu {
                Button(L.t("macScreen.home.openViewNewTab", "View Only in New Tab")) { actions.openDeviceInNewTab(device.id, .view) }
                Button(L.t("macScreen.home.openControlNewTab", "Full Control in New Tab")) { actions.openDeviceInNewTab(device.id, .full) }
                Divider()
                Menu(L.t("macScreen.home.changeAccess", "Change Access…")) {
                    ForEach(MacScreenAccess.all, id: \.value) { option in
                        Toggle(option.title, isOn: Binding(get: { access == option.scope }, set: { on in
                            guard on else { return }
                            setAccess(option.scope, device: device, hub: hub)
                        }))
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .macScreenMenu(colors.secondary)
            .accessibilityIdentifier("macScreen.home.more.\(device.name)")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if access != .none { actions.openDevice(device.id, nil) } }
    }

    /// The speed run: this Mac's access becomes Ask (the host's prompt then offers
    /// Always Allow), and the tab asks for `scope`.
    private func askForAccess(_ device: HubDevice, scope: SessionScope, hub: DeviceHub) {
        let me = hub.identity.id
        // task-owner: one permission write before the request
        Task {
            try? await hub.setPermission(host: device.id, viewer: me, scope: .ask)
            actions.openDevice(device.id, scope)
        }
    }

    private func setAccess(_ scope: DeviceScope, device: HubDevice, hub: DeviceHub) {
        let me = hub.identity.id
        // task-owner: one permission write; the hub pushes the change to both Macs
        Task { try? await hub.setPermission(host: device.id, viewer: me, scope: scope) }
    }

    // MARK: Allow Mac Screen on This Mac

    private func sharing(_ hub: DeviceHub) -> some View {
        let hubHost = devices.hubHost
        return MacScreenSection(title: L.t("macScreen.home.allowTitle", "Allow Mac Screen on This Mac")) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(get: { hubHost.isSharing }, set: { on in
                    // task-owner: one sharing write; the switch follows the hub's record
                    Task { try? await hubHost.setSharing(on) }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("macScreen.home.allowToggle", "Allow Mac Screen on this Mac"))
                        Text(L.t("macScreen.home.allowDetail", "Your other devices signed in to this cmux account can ask to see or control this Mac. You approve each device, or choose its access in Settings › Devices."))
                            .font(MacScreenType.caption).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .tint(colors.focus)
                .disabled(hubHost.busy)
                .accessibilityIdentifier("macScreen.home.allowToggle")
                if hubHost.isSharing {
                    MacScreenDivider()
                    MacScreenPermissionRow(title: L.t("macScreen.home.screenRecording", "Screen Recording"),
                                           detail: L.t("macScreen.home.screenRecordingDetail", "Lets cmux send this screen. macOS may ask you to quit and reopen cmux."),
                                           granted: host.screenRecordingGranted) { host.openSettings(screenRecording: true) }
                    MacScreenPermissionRow(title: L.t("macScreen.home.accessibility", "Accessibility"),
                                           detail: L.t("macScreen.home.accessibilityDetail", "Lets the other Mac click and type here. Without it, it can only watch."),
                                           granted: host.accessibilityGranted) { host.openSettings(screenRecording: false) }
                    MacScreenDivider()
                    sessionRow(hubHost)
                }
                if let error = hubHost.lastError {
                    Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(colors.danger).font(MacScreenType.caption)
                }
            }
            .padding(14)
        }
        .onAppear { host.refreshPermissions() }
    }

    private func sessionRow(_ hubHost: MacScreenHubHost) -> some View {
        HStack(spacing: 8) {
            Circle().fill(hubHost.session?.connected == true ? colors.accent : colors.success).frame(width: 8, height: 8)
            Text(sessionText(hubHost)).accessibilityIdentifier("macScreen.home.hubStatus")
            Spacer()
            if hubHost.session != nil {
                Button(L.t("macScreen.indicator.revoke", "Revoke This Device"), action: hubHost.revokeViewer)
                    .buttonStyle(MacScreenButtonStyle(compact: true))
                Button(L.t("macScreen.indicator.stop", "Stop Sharing This Mac")) { hubHost.stopSession() }
                    .buttonStyle(MacScreenButtonStyle(role: .destructive, compact: true))
            }
        }
    }

    private func sessionText(_ hubHost: MacScreenHubHost) -> String {
        guard let session = hubHost.session else { return L.t("macScreen.home.hubReady", "Ready. Your devices can connect.") }
        if !session.connected { return String(format: L.t("macScreen.home.hubConnecting", "%@ is connecting…"), session.viewerName) }
        return session.scope == .view
            ? String(format: L.t("macScreen.indicator.viewing", "%@ is viewing this Mac"), session.viewerName)
            : String(format: L.t("macScreen.indicator.controlling", "%@ is controlling this Mac"), session.viewerName)
    }

    private func note(_ text: String) -> some View {
        Text(text).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
    }
}

/// A titled group card of the home page.
struct MacScreenSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.macScreenColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(MacScreenType.header).foregroundStyle(colors.secondary)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(colors.card, in: RoundedRectangle(cornerRadius: Metrics.panelCornerRadius, style: .continuous))
                .overlay {
                    if colors.borders {
                        RoundedRectangle(cornerRadius: Metrics.panelCornerRadius, style: .continuous).strokeBorder(colors.separator)
                    }
                }
        }
    }
}

/// A hairline between rows of a group card.
struct MacScreenDivider: View {
    @Environment(\.macScreenColors) private var colors

    var body: some View {
        (colors.borders ? colors.separator : colors.hover).frame(height: 1)
    }
}

/// A permission's row: granted, or a button that opens its System Settings pane.
struct MacScreenPermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    var action: String?
    let open: () -> Void
    @Environment(\.macScreenColors) private var colors

    init(title: String, detail: String, granted: Bool, action: String? = nil, open: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.granted = granted
        self.action = action
        self.open = open
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? colors.success : colors.attention)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(MacScreenType.emphasized)
                Text(detail).font(MacScreenType.caption).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Text(L.t("macScreen.home.granted", "Allowed")).font(MacScreenType.caption).foregroundStyle(colors.secondary)
            } else {
                Button(action ?? L.t("macScreen.home.openSettings", "Open System Settings"), action: open)
                    .buttonStyle(MacScreenButtonStyle(compact: true))
            }
        }
    }
}

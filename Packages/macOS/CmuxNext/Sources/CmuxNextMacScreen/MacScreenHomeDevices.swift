import AppKit
import CmuxNextDesign
import CmuxNextDevices
import Foundation

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

/// What the home page shows, as values: the page builds its rows from this
/// and again only when it changes (the snapshot boundary: rows never hold
/// the hub or the host).
struct MacScreenHomeSnapshot: Equatable {
    /// One of the user's devices that shares Mac Screen.
    struct Device: Equatable {
        var id: String
        var name: String
        var isPhone: Bool
        var online: Bool
        /// This Mac's access to it.
        var access: MacScreenAccess
    }

    /// Your Devices: a note (signed out, loading, none shared) or the list.
    enum Devices: Equatable {
        case note(String)
        case list([Device])
    }

    /// Allow Mac Screen on This Mac.
    struct Sharing: Equatable {
        var isSharing: Bool
        var busy: Bool
        var screenRecordingGranted: Bool
        var accessibilityGranted: Bool
        var session: MacScreenHubHost.Session?
        var lastError: String?
    }

    struct Keyboard: Equatable {
        var enabled: Bool
        var needsAccessibility: Bool
    }

    var devices: Devices?
    var sharing: Sharing?
    var keyboard: Keyboard?
    /// The type scale the rows were built at (`MacScreenType.sizes`).
    var typeSizes = MacScreenType.sizes

    /// The hosts listed, whose permission lists the page reads.
    var deviceIDs: [String] {
        guard case let .list(devices) = devices else { return [] }
        return devices.map(\.id)
    }

    /// Reads `home`'s models (under Observation, so a change of any value read here redraws the page).
    @MainActor
    init(home: MacScreenHomeView) {
        if let source = home.devices {
            if let hub = source.box.hub {
                let shared = hub.otherDevices.filter(\.macScreenShared)
                if shared.isEmpty {
                    devices = .note(hub.status == .ready || hub.status == .idle
                        ? L.t("macScreen.home.noSharedDevices", "None of your other devices share Mac Screen. On the Mac you want to see, turn on Allow Mac Screen on this Mac.")
                        : L.t("macScreen.home.devicesLoading", "Loading your devices…"))
                } else {
                    devices = .list(shared.map { device in
                        Device(id: device.id, name: device.name, isPhone: device.platform == .ios, online: device.online,
                               access: MacScreenAccess(hub.scope(host: device.id, viewer: hub.identity.id)))
                    })
                }
                if hub.thisDevice != nil {
                    let hubHost = source.hubHost
                    sharing = Sharing(isSharing: hubHost.isSharing, busy: hubHost.busy,
                                      screenRecordingGranted: home.host.screenRecordingGranted,
                                      accessibilityGranted: home.host.accessibilityGranted,
                                      session: hubHost.session, lastError: hubHost.lastError)
                }
            } else {
                devices = .note(Self.setupNote(configured: source.box.configured))
            }
        }
        if let shortcuts = home.systemShortcuts {
            keyboard = Keyboard(enabled: shortcuts.enabled, needsAccessibility: shortcuts.needsAccessibility)
        }
    }

    /// What the home page says while Mac Screen cannot work: it needs a
    /// signed-in cmux account, and a DEV build's Device Hub Address override
    /// (Settings › Development) must be valid when set.
    static func setupNote(configured: Bool) -> String {
        guard configured else {
            return L.t("macScreen.home.invalidHubAddress", "Mac Screen works through the device hub. The Device Hub Address in Settings › Development is not a valid web address; fix it, or clear it to use the built-in hub.")
        }
        return L.t("macScreen.home.devicesSignIn", "Sign in to cmux to see your other Macs here.")
    }
}

/// The home page's device hub sections: Your Devices (the user's other
/// devices that share Mac Screen, online state and this Mac's access to
/// each, Connect with View Only or Full Control, Change Access) and Allow
/// Mac Screen on This Mac (the switch, its permissions and who is
/// connected).
extension MacScreenHomeView {
    // MARK: Your Devices

    func yourDevices(_ devices: MacScreenHomeSnapshot.Devices) -> NSView {
        let content: NSView
        switch devices {
        case let .note(text):
            content = MacScreenHomeParts.note(text)
        case let .list(list):
            let rows = MacScreenStack.make(.vertical, spacing: 0, alignment: .leading)
            for device in list {
                MacScreenStack.addFullWidth(deviceRow(device), to: rows)
                if device.id != list.last?.id, colors.borders {
                    let line = MacScreenFill(\.separator)
                    line.heightAnchor.constraint(equalToConstant: 1).isActive = true
                    let inset = NSView()
                    inset.translatesAutoresizingMaskIntoConstraints = false
                    inset.addSubview(line)
                    NSLayoutConstraint.activate([
                        line.leadingAnchor.constraint(equalTo: inset.leadingAnchor, constant: 50),
                        line.trailingAnchor.constraint(equalTo: inset.trailingAnchor),
                        line.topAnchor.constraint(equalTo: inset.topAnchor),
                        line.bottomAnchor.constraint(equalTo: inset.bottomAnchor),
                    ])
                    MacScreenStack.addFullWidth(inset, to: rows)
                }
            }
            content = rows
        }
        return MacScreenHomeParts.section(L.t("macScreen.home.yourDevices", "Your Devices"), content: content)
    }

    private func deviceRow(_ device: MacScreenHomeSnapshot.Device) -> NSView {
        let glyph = MacScreenGlyph(device.isPhone ? "iphone" : "desktopcomputer", font: MacScreenType.glyph, width: 26)
        let status = MacScreenStack.make(.horizontal, spacing: 6, alignment: .centerY, [
            MacScreenFill.dot(device.online ? \.success : \.tertiary, side: 7),
            MacScreenText(device.online ? L.t("macScreen.home.online", "Online") : L.t("macScreen.home.offline", "Offline"),
                          font: MacScreenType.caption, ink: \.secondary),
            MacScreenText("·", font: MacScreenType.caption, ink: \.secondary),
            MacScreenText(String(format: L.t("macScreen.home.access", "Your access: %@"), device.access.title),
                          font: MacScreenType.caption, ink: \.secondary),
        ])
        let name = MacScreenText(device.name, font: MacScreenType.emphasized)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let labels = MacScreenStack.make(.vertical, spacing: 2, alignment: .leading, [name, status])
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [glyph, labels, MacScreenSpacer()]
        if !device.access.allowsRequests {
            // None: the host blocked this Mac, and the hub refuses a request without a prompt.
            let blocked = MacScreenText(String(format: L.t("macScreen.home.blocked", "%1$@ doesn’t allow this Mac. Change it on %2$@ in Settings › Devices."),
                                               device.name, device.name),
                                        font: MacScreenType.caption, ink: \.secondary, wraps: true, alignment: .right, width: 260)
            blocked.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
            blocked.setAccessibilityIdentifier("macScreen.home.blocked.\(device.name)")
            views.append(blocked)
        } else {
            let id = device.id
            views.append(MacScreenButton(L.t("macScreen.hub.view", "View Only"), id: "macScreen.home.view.\(device.name)") { [weak self] in
                self?.actions.openDevice(id, .view)
            })
            views.append(MacScreenButton(L.t("macScreen.hub.control", "Full Control"), role: .primary, id: "macScreen.home.control.\(device.name)") { [weak self] in
                self?.actions.openDevice(id, .full)
            })
            let more = MacScreenMenuButton(symbol: "ellipsis.circle", accessibilityTitle: nil, id: "macScreen.home.more.\(device.name)")
            more.makeMenu = { [weak self] in self?.moreMenu(id) ?? NSMenu() }
            views.append(more)
        }
        let stack = MacScreenStack.make(.horizontal, spacing: 12, alignment: .centerY, views,
                                        insets: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))
        let row = MacScreenRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            stack.topAnchor.constraint(equalTo: row.topAnchor),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            // The name and status lines keep the row's 10-point padding above and below them, as the
            // SwiftUI row's did: a centered stack alone sizes the row to its buttons and lets the
            // two lines run into the padding (a row 4 points shorter than before the port).
            labels.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 10),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -10),
        ])
        if device.access.allowsRequests {
            let id = device.id
            row.onDoubleClick = { [weak self] in self?.actions.openDevice(id, nil) }
        }
        return row
    }

    /// The row's More menu: open in a new tab, or ask the host for access.
    private func moreMenu(_ id: String) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem.macScreen(L.t("macScreen.home.openViewNewTab", "View Only in New Tab")) { [weak self] in
            self?.actions.openDeviceInNewTab(id, .view)
        })
        menu.addItem(NSMenuItem.macScreen(L.t("macScreen.home.openControlNewTab", "Full Control in New Tab")) { [weak self] in
            self?.actions.openDeviceInNewTab(id, .full)
        })
        menu.addItem(.separator())
        // Only the host sets access to itself: from here this Mac asks, and the
        // host's prompt offers Always Allow.
        let ask = NSMenu()
        ask.autoenablesItems = false
        ask.addItem(NSMenuItem.macScreen(L.t("macScreen.hub.view", "View Only")) { [weak self] in self?.actions.openDevice(id, .view) })
        ask.addItem(NSMenuItem.macScreen(L.t("macScreen.hub.control", "Full Control")) { [weak self] in self?.actions.openDevice(id, .full) })
        let request = NSMenuItem(title: L.t("macScreen.home.requestAccess", "Ask for Access"), action: nil, keyEquivalent: "")
        request.submenu = ask
        menu.addItem(request)
        return menu
    }

    // MARK: Allow Mac Screen on This Mac

    func sharingSection(_ sharing: MacScreenHomeSnapshot.Sharing) -> NSView {
        let content = MacScreenHomeParts.cardColumn()
        let hubHost = devices?.hubHost
        let toggle = MacScreenHomeParts.switchRow(
            title: L.t("macScreen.home.allowToggle", "Allow Mac Screen on this Mac"),
            detail: L.t("macScreen.home.allowDetail", "Your other devices signed in to this cmux account can ask to see or control this Mac. You approve each device, or choose its access in Settings › Devices."),
            isOn: sharing.isSharing, enabled: !sharing.busy, id: "macScreen.home.allowToggle"
        ) { [weak self] on in
            // task-owner: one sharing write; the switch follows the hub's record
            Task { try? await hubHost?.setSharing(on) }
            // The switch shows the hub's record: back to it if the write does not change it.
            self?.syncSwitchesSoon()
        }
        MacScreenStack.addFullWidth(toggle, to: content)
        if sharing.isSharing {
            MacScreenStack.addFullWidth(MacScreenFill.divider(), to: content)
            MacScreenStack.addFullWidth(MacScreenHomeParts.permissionRow(
                title: L.t("macScreen.home.screenRecording", "Screen Recording"),
                detail: L.t("macScreen.home.screenRecordingDetail", "Lets cmux send this screen. macOS may ask you to quit and reopen cmux."),
                granted: sharing.screenRecordingGranted
            ) { [weak self] in self?.host.openSettings(screenRecording: true) }, to: content)
            MacScreenStack.addFullWidth(MacScreenHomeParts.permissionRow(
                title: L.t("macScreen.home.accessibility", "Accessibility"),
                detail: L.t("macScreen.home.accessibilityDetail", "Lets the other Mac click and type here. Without it, it can only watch."),
                granted: sharing.accessibilityGranted
            ) { [weak self] in self?.host.openSettings(screenRecording: false) }, to: content)
            MacScreenStack.addFullWidth(MacScreenFill.divider(), to: content)
            MacScreenStack.addFullWidth(sessionRow(sharing.session), to: content)
        }
        if let error = sharing.lastError {
            let row = MacScreenStack.make(.horizontal, spacing: 6, alignment: .firstBaseline, [
                MacScreenGlyph("exclamationmark.circle.fill", font: MacScreenType.caption, ink: \.danger),
                MacScreenText(error, font: MacScreenType.caption, ink: \.danger, wraps: true),
            ])
            MacScreenStack.addFullWidth(row, to: content)
        }
        return MacScreenHomeParts.section(L.t("macScreen.home.allowTitle", "Allow Mac Screen on This Mac"), content: content)
    }

    private func sessionRow(_ session: MacScreenHubHost.Session?) -> NSView {
        let status = MacScreenText(Self.sessionText(session), font: MacScreenType.body)
        status.setAccessibilityIdentifier("macScreen.home.hubStatus")
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [MacScreenFill.dot(session?.connected == true ? \.litGlyph : \.success, side: 8), status, MacScreenSpacer()]
        if session != nil {
            let hubHost = devices?.hubHost
            views.append(MacScreenButton(L.t("macScreen.indicator.revoke", "Revoke This Device"), compact: true) { hubHost?.revokeViewer() })
            views.append(MacScreenButton(L.t("macScreen.indicator.stop", "Stop Sharing This Mac"), role: .destructive, compact: true) {
                hubHost?.stopSession()
            })
        }
        return MacScreenStack.make(.horizontal, spacing: 8, alignment: .centerY, views)
    }

    static func sessionText(_ session: MacScreenHubHost.Session?) -> String {
        guard let session else { return L.t("macScreen.home.hubReady", "Ready. Your devices can connect.") }
        if !session.connected { return String(format: L.t("macScreen.home.hubConnecting", "%@ is connecting…"), session.viewerName) }
        return session.scope == .view
            ? String(format: L.t("macScreen.indicator.viewing", "%@ is viewing this Mac"), session.viewerName)
            : String(format: L.t("macScreen.indicator.controlling", "%@ is controlling this Mac"), session.viewerName)
    }
}

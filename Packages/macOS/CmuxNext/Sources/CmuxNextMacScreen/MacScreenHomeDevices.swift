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

    /// Your Devices: a note (signed out, loading, none shared), an error, or the list.
    enum Devices: Equatable {
        case note(String)
        /// Signed out of cmux: the note, then the shared Sign In button (``SignInButton``).
        case signedOut(String)
        /// The device hub could not be reached or the list not read: the note, then Try Again
        /// (``MacScreenHomeView/retryDevices()``).
        case failed(String)
        case list([Device])

        /// The note text this state shows (signed out, an error or a note), or nil for the list.
        var note: String? {
            switch self {
            case let .note(text), let .signedOut(text), let .failed(text): text
            case .list: nil
            }
        }
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
    /// The look of Allow Mac Screen on This Mac (Debug Settings `macScreen.sharingLook`).
    var sharingLook = MacScreenTunables.sharingLook.value

    /// The hosts listed, whose permission lists the page reads.
    var deviceIDs: [String] {
        guard case let .list(devices) = devices else { return [] }
        return devices.map(\.id)
    }

    /// A snapshot of given values (tests and galleries draw the page from it with `MacScreenHomeView.build`).
    init(devices: Devices? = nil, sharing: Sharing? = nil, keyboard: Keyboard? = nil, sharingLook: MacScreenSharingLook) {
        self.devices = devices
        self.sharing = sharing
        self.keyboard = keyboard
        self.sharingLook = sharingLook
    }

    /// Reads `home`'s models (under Observation, so a change of any value read here redraws the page).
    @MainActor
    init(home: MacScreenHomeView) {
        if let source = home.devices {
            if let hub = source.box.hub {
                let shared = hub.otherDevices.filter(\.macScreenShared)
                if shared.isEmpty {
                    devices = Self.noDevicesShown(status: hub.status, listed: hub.devicesListed,
                                                  listFailed: hub.devicesListError != nil)
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
                devices = Self.setupDevices(configured: source.box.configured)
            }
        }
        if let shortcuts = home.systemShortcuts {
            keyboard = Keyboard(enabled: shortcuts.enabled, needsAccessibility: shortcuts.needsAccessibility)
        }
    }

    /// What Your Devices says with no shared device to list (ui-state-fixes M5): "None of your
    /// other devices share Mac Screen" only once the hub is registered and the list was read; a
    /// hub not started yet (`idle`) or starting is loading; a hub that failed to start, or a list
    /// read that failed with nothing read, is an error with Try Again, never loading forever.
    static func noDevicesShown(status: DeviceHub.Status, listed: Bool, listFailed: Bool) -> Devices {
        switch status {
        case .failed:
            return .failed(L.t("macScreen.home.devicesFailed", "Couldn’t reach the device hub to load your devices."))
        case .ready where listed:
            return .note(L.t("macScreen.home.noSharedDevices", "None of your other devices share Mac Screen. On the Mac you want to see, turn on Allow Mac Screen on this Mac."))
        case .ready where listFailed:
            return .failed(L.t("macScreen.home.devicesFailed", "Couldn’t reach the device hub to load your devices."))
        case .idle, .starting, .ready:
            return .note(L.t("macScreen.home.devicesLoading", "Loading your devices…"))
        }
    }

    /// What the home page says while Mac Screen cannot work: it needs a
    /// signed-in cmux account, and a DEV build's Device Hub Address override
    /// (Settings › Development) must be valid when set.
    static func setupDevices(configured: Bool) -> Devices {
        guard configured else {
            return .note(L.t("macScreen.home.invalidHubAddress", "Mac Screen works through the device hub. The Device Hub Address in Settings › Development is not a valid web address; fix it, or clear it to use the built-in hub."))
        }
        return .signedOut(L.t("macScreen.home.devicesSignIn", "Sign in to cmux to see your other Macs here."))
    }
}

/// The home page's Your Devices section: the user's other devices that
/// share Mac Screen, online state and this Mac's access to each, Connect
/// with View Only or Full Control, Change Access. Allow Mac Screen on This
/// Mac is in `MacScreenHomeView+Sharing.swift`.
extension MacScreenHomeView {
    // MARK: Your Devices

    func yourDevices(_ devices: MacScreenHomeSnapshot.Devices) -> NSView {
        let content: NSView
        switch devices {
        case let .note(text):
            content = MacScreenHomeParts.note(text)
        case let .failed(text):
            let retry = MacScreenButton(L.t("macScreen.card.retry", "Try Again"), id: "macScreen.home.devicesRetry") { [weak self] in
                self?.retryDevices()
            }
            content = MacScreenHomeParts.note(text, action: retry)
        case let .signedOut(text):
            let signIn = SignInButton { [weak self] in self?.actions.signIn() }
            signIn.setAccessibilityIdentifier("macScreen.home.signIn")
            content = MacScreenHomeParts.note(text, action: signIn)
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

    /// Try Again under a failed Your Devices: a hub that failed to start starts again; one that
    /// is registered reads its device list again. The page redraws from the hub's state.
    func retryDevices() {
        guard let hub = devices?.box.hub else { return }
        // task-owner: one hub start or list read; ends with it (the hub drops a stale generation's answer)
        Task {
            if case .failed = hub.status { await hub.start() } else { await hub.refreshDevices() }
        }
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
}

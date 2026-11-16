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
    let store: MacScreenStore

    init(pages: MacScreenPages) {
        box = pages.hubBox
        hubHost = pages.hubHost
        store = pages.store
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
        var macScreenShared: Bool
        /// This Mac's access to it.
        var access: MacScreenAccess
        /// The hub's online word is current (this Mac's own hub link is up); false: `online` may be stale.
        var onlineKnown = true
    }

    /// Your Devices: a note (signed out, loading, none shared) or the list.
    enum Devices: Equatable {
        case note(String)
        /// Signed out of cmux: the note, then the shared Sign In button (``SignInButton``).
        case signedOut(String)
        case list([Device])

        /// The note text this state shows (signed out or a note), or nil for the list.
        var note: String? {
            switch self {
            case let .note(text), let .signedOut(text): text
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
        var showFirstUse: Bool

        init(isSharing: Bool, busy: Bool, screenRecordingGranted: Bool, accessibilityGranted: Bool,
             session: MacScreenHubHost.Session? = nil, lastError: String? = nil, showFirstUse: Bool = false) {
            self.isSharing = isSharing
            self.busy = busy
            self.screenRecordingGranted = screenRecordingGranted
            self.accessibilityGranted = accessibilityGranted
            self.session = session
            self.lastError = lastError
            self.showFirstUse = showFirstUse
        }
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
    /// The look of Your Devices (Debug Settings `macScreen.devicesLook`).
    var devicesLook = MacScreenTunables.devicesLook.value

    /// The hosts listed, whose permission lists the page reads.
    var deviceIDs: [String] {
        guard case let .list(devices) = devices else { return [] }
        return devices.map(\.id)
    }

    /// A snapshot of given values (tests and galleries draw the page from it with `MacScreenHomeView.build`).
    init(devices: Devices? = nil, sharing: Sharing? = nil, keyboard: Keyboard? = nil, sharingLook: MacScreenSharingLook,
         devicesLook: MacScreenDevicesLook = .quiet) {
        self.devices = devices
        self.sharing = sharing
        self.keyboard = keyboard
        self.sharingLook = sharingLook
        self.devicesLook = devicesLook
    }

    /// Reads `home`'s models (under Observation, so a change of any value read here redraws the page).
    @MainActor
    init(home: MacScreenHomeView) {
        if let source = home.devices {
            if let hub = source.box.hub {
                let listed = Self.listed(hub.otherDevices)
                if listed.isEmpty {
                    devices = .note(hub.status == .ready || hub.status == .idle
                        ? L.t("macScreen.home.noSharedDevices", "None of your other devices share Mac Screen. On the Mac you want to see, turn on Allow Mac Screen on this Mac.")
                        : L.t("macScreen.home.devicesLoading", "Loading your devices…"))
                } else {
                    devices = .list(listed.map { device in
                        Self.device(device, access: MacScreenAccess(hub.scope(host: device.id, viewer: hub.identity.id)),
                                    hubConnected: hub.connection == .connected)
                    })
                }
                if hub.thisDevice != nil {
                    let hubHost = source.hubHost
                    sharing = Sharing(isSharing: hubHost.isSharing, busy: hubHost.busy,
                                      screenRecordingGranted: home.host.screenRecordingGranted,
                                      accessibilityGranted: home.host.accessibilityGranted,
                                      session: hubHost.session, lastError: hubHost.lastError,
                                      showFirstUse: Self.showsFirstUse(store: source.store, isSharing: hubHost.isSharing))
                }
            } else {
                devices = source.box.startupMessage.map(Devices.note) ?? Self.setupDevices(configured: source.box.configured)
            }
        }
        if let shortcuts = home.systemShortcuts {
            keyboard = Keyboard(enabled: shortcuts.enabled, needsAccessibility: shortcuts.needsAccessibility)
        }
    }

    /// One hub device as the page shows it.
    static func device(_ device: HubDevice, access: MacScreenAccess, hubConnected: Bool) -> Device {
        Device(id: device.id, name: device.name, isPhone: device.platform == .ios, online: device.online,
               macScreenShared: device.macScreenShared, access: access, onlineKnown: hubConnected)
    }

    /// Whether the page opens with the first-use steps: until this Mac has shared or viewed once.
    @MainActor
    static func showsFirstUse(store: MacScreenStore, isSharing: Bool) -> Bool {
        !store.hasUsedBefore && !isSharing
    }

    /// The devices the page lists: every other Mac, online or not, sharing or not, so the page can say how to
    /// reach it; a phone only when it shares, since its row could only say to turn on what a phone cannot.
    static func listed(_ devices: [HubDevice]) -> [HubDevice] {
        devices.filter { $0.platform != .ios || $0.macScreenShared }
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

    func yourDevices(_ devices: MacScreenHomeSnapshot.Devices, look: MacScreenDevicesLook = .quiet) -> NSView {
        let content: NSView
        switch devices {
        case let .note(text):
            content = MacScreenHomeParts.note(text)
        case let .signedOut(text):
            let signIn = SignInButton { [weak self] in self?.actions.signIn() }
            signIn.setAccessibilityIdentifier("macScreen.home.signIn")
            content = MacScreenStack.make(.vertical, spacing: 8, alignment: .leading, [MacScreenHomeParts.note(text), signIn])
        case let .list(list):
            let rows = MacScreenStack.make(.vertical, spacing: 0, alignment: .leading)
            let views = look == .classic ? list.map(classicRow) : quietRows(list, look: look)
            for (index, view) in views.enumerated() {
                MacScreenStack.addFullWidth(view, to: rows)
                if index < views.count - 1, colors.borders { MacScreenStack.addFullWidth(rowSeparator(), to: rows) }
            }
            content = rows
        }
        return MacScreenHomeParts.section(L.t("macScreen.home.yourDevices", "Your Devices"), content: content)
    }

    private func rowSeparator() -> NSView {
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
        return inset
    }

    // MARK: Quiet rows (Leo 2026-11-16: "this needs to shut up")

    /// What a row can do now, which is all it says.
    enum RowState: Equatable {
        /// Online, sharing, and it lets this Mac ask: name, dot, View Only and Full Control.
        case usable
        /// Online, sharing off: one word, no buttons.
        case sharingOff
        /// Online, and it does not let this Mac in: one word, no buttons.
        case blocked
        /// Offline: the name alone, dim.
        case offline
    }

    static func rowState(_ device: MacScreenHomeSnapshot.Device) -> RowState {
        // Offline counts only while this Mac's hub link is up; until then the hub's word may be stale and the
        // row stays openable (the pane's Connect card says what it finds).
        guard device.online || !device.onlineKnown else { return .offline }
        if !device.access.allowsRequests { return .blocked }
        return device.macScreenShared ? .usable : .sharingOff
    }

    /// Viewable Macs first, then online ones that are not, then offline ones (folded, listed or counted by `look`).
    private func quietRows(_ list: [MacScreenHomeSnapshot.Device], look: MacScreenDevicesLook) -> [NSView] {
        let order: [RowState] = [.usable, .sharingOff, .blocked]
        var views = order.flatMap { state in list.filter { Self.rowState($0) == state }.map { quietRow($0, state: state) } }
        let offline = list.filter { Self.rowState($0) == .offline }
        guard !offline.isEmpty else { return views }
        switch look {
        case .quiet:
            views.append(offlineGroupRow(count: offline.count))
            if offlineExpanded { views += offline.map { quietRow($0, state: .offline) } }
        case .offlineLines, .classic:
            views += offline.map { quietRow($0, state: .offline) }
        case .onlineOnly:
            let count = MacScreenText(String(format: L.t("macScreen.home.offlineCount", "%d offline"), offline.count),
                                      font: MacScreenType.caption, ink: \.tertiary)
            count.setAccessibilityIdentifier("macScreen.home.offlineCount")
            views.append(MacScreenStack.make(.horizontal, spacing: 0, alignment: .centerY, [count, MacScreenSpacer()],
                                             insets: NSEdgeInsets(top: 8, left: 54, bottom: 8, right: 14)))
        }
        return views
    }

    private func quietRow(_ device: MacScreenHomeSnapshot.Device, state: RowState) -> NSView {
        let offline = state == .offline
        let glyph = MacScreenGlyph(device.isPhone ? "iphone" : "desktopcomputer", font: MacScreenType.glyph,
                                   ink: offline ? \.tertiary : \.secondary, width: 26)
        let name = MacScreenText(device.name, font: offline ? MacScreenType.body : MacScreenType.emphasized,
                                 ink: offline ? \.secondary : \.primary)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setAccessibilityIdentifier("macScreen.home.name.\(device.name)")
        var views: [NSView] = [glyph, name]
        if !offline { views.append(MacScreenFill.dot(\.success, side: 7)) }
        views.append(MacScreenSpacer())
        let id = device.id
        switch state {
        case .usable:
            views.append(MacScreenButton(L.t("macScreen.hub.view", "View Only"), id: "macScreen.home.view.\(device.name)") { [weak self] in
                self?.actions.openDevice(id, .view)
            })
            views.append(MacScreenButton(L.t("macScreen.hub.control", "Full Control"), role: .primary, id: "macScreen.home.control.\(device.name)") { [weak self] in
                self?.actions.openDevice(id, .full)
            })
            let more = MacScreenMenuButton(symbol: "ellipsis.circle", accessibilityTitle: nil, id: "macScreen.home.more.\(device.name)")
            more.makeMenu = { [weak self] in self?.moreMenu(id) ?? NSMenu() }
            views.append(more)
        case .sharingOff, .blocked:
            let word = state == .blocked ? L.t("macScreen.home.blockedShort", "Not allowed")
                : L.t("macScreen.home.sharingOff", "Sharing off")
            let reason = MacScreenText(word, font: MacScreenType.caption, ink: \.secondary)
            reason.setContentCompressionResistancePriority(.required, for: .horizontal)
            reason.setAccessibilityIdentifier("macScreen.home.\(state == .blocked ? "blocked" : "notShared").\(device.name)")
            views.append(reason)
        case .offline:
            break
        }
        let vertical: CGFloat = offline ? 6 : 10
        let stack = MacScreenStack.make(.horizontal, spacing: 10, alignment: .centerY, views,
                                        insets: NSEdgeInsets(top: vertical, left: 14, bottom: vertical, right: 14))
        let row = MacScreenRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            stack.topAnchor.constraint(equalTo: row.topAnchor),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        if state == .usable { row.onDoubleClick = { [weak self] in self?.actions.openDevice(id, nil) } }
        return row
    }

    /// The quiet look's one row for every offline Mac: a chevron, "Offline" and the count; a click opens it.
    private func offlineGroupRow(count: Int) -> NSView {
        let button = MacScreenButton(String(format: L.t("macScreen.home.offlineGroup", "Offline (%d)"), count), role: .icon,
                                     symbol: offlineExpanded ? "chevron.down" : "chevron.right",
                                     id: "macScreen.home.offlineGroup") { [weak self] in
            guard let self else { return }
            offlineExpanded.toggle()
            if let built { build(built) }
        }
        button.setAccessibilityValue(offlineExpanded ? "expanded" : "collapsed")
        return MacScreenStack.make(.horizontal, spacing: 0, alignment: .centerY, [button, MacScreenSpacer()],
                                   insets: NSEdgeInsets(top: 6, left: 48, bottom: 6, right: 14))
    }

    // MARK: Classic rows (Debug Settings `macScreen.devicesLook` = classic)

    private func classicRow(_ device: MacScreenHomeSnapshot.Device) -> NSView {
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
        var labelViews: [NSView] = [name, status]
        if device.access.scope == .ask {
            labelViews.append(MacScreenText(L.t("macScreen.home.askDetail", "The first connect asks on that Mac."),
                                            font: MacScreenType.caption, ink: \.secondary, wraps: true))
        }
        let labels = MacScreenStack.make(.vertical, spacing: 2, alignment: .leading, labelViews)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [glyph, labels, MacScreenSpacer()]
        // Offline counts only while this Mac's hub link is up; until then the hub's word may be stale and the
        // row stays openable (the pane's Connect card says what it finds).
        let reachable = device.online || !device.onlineKnown
        // Why the row can't connect, and its id: offline first, then a host that blocks this Mac (the hub refuses
        // a request without a prompt, so turning sharing on would not help), then sharing off.
        let unavailable: (text: String, id: String)? = if !reachable {
            (String(format: L.t("macScreen.home.offlineDetail", "Open cmux on %@ to share its screen."), device.name), "offline")
        } else if !device.access.allowsRequests {
            (String(format: L.t("macScreen.home.blocked", "%1$@ doesn’t allow this Mac. Change it on %2$@ in Settings › Devices."),
                    device.name, device.name), "blocked")
        } else if !device.macScreenShared {
            (String(format: L.t("macScreen.home.notSharedDetail", "Turn on Allow Mac Screen on %@ to share its screen."), device.name),
             "notShared")
        } else {
            nil
        }
        if let unavailable {
            let reason = MacScreenText(unavailable.text, font: MacScreenType.caption, ink: \.secondary, wraps: true, alignment: .right, width: 260)
            reason.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
            reason.setAccessibilityIdentifier("macScreen.home.\(unavailable.id).\(device.name)")
            views.append(reason)
        }
        if reachable, device.macScreenShared, device.access.allowsRequests {
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
        } else if device.access.allowsRequests {
            let view = MacScreenButton(L.t("macScreen.hub.view", "View Only"), id: "macScreen.home.view.\(device.name)") {}
            view.isEnabled = false
            let control = MacScreenButton(L.t("macScreen.hub.control", "Full Control"), role: .primary, id: "macScreen.home.control.\(device.name)") {}
            control.isEnabled = false
            views.append(view)
            views.append(control)
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
        if reachable, device.macScreenShared, device.access.allowsRequests {
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

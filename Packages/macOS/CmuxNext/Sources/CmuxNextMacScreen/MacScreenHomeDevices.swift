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
    /// Set up cmux and Start cmux on a Mac of the list.
    let setup: MacScreenDeviceSetup

    init(pages: MacScreenPages) {
        box = pages.hubBox
        hubHost = pages.hubHost
        store = pages.store
        setup = pages.deviceSetup
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
        /// Set up cmux, Start cmux and the run's steps (a Mac only, when the daemon knows `device-setup`).
        var setup = MacScreenDeviceSetupRow.none
        /// The hub's platform (nil: a record from before platforms; `glyph`, `viewable` read it).
        var platform: DevicePlatform?
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
        /// Why the switch waits: this Mac is not on the device hub yet (connecting, or why it could not). nil once
        /// it is. This Mac is drawn either way, so a person (or a probe) sees the section and the permissions while
        /// the hub reconnects, not a page with only Your Devices (chevron run 45954248647).
        var hubNote: String?

        init(isSharing: Bool, busy: Bool, screenRecordingGranted: Bool, accessibilityGranted: Bool,
             session: MacScreenHubHost.Session? = nil, lastError: String? = nil, showFirstUse: Bool = false,
             hubNote: String? = nil) {
            self.isSharing = isSharing
            self.busy = busy
            self.screenRecordingGranted = screenRecordingGranted
            self.accessibilityGranted = accessibilityGranted
            self.session = session
            self.lastError = lastError
            self.showFirstUse = showFirstUse
            self.hubNote = hubNote
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
    /// Where a classic row puts Set up cmux and Start cmux (the gallery draws each; the page draws the default).
    var setupPlacement = MacScreenSetupPlacement.standard

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
                    devices = .note(Self.emptyNote(DeviceDiscovery.of(hub, shown: 0)))
                } else {
                    devices = .list(listed.map { device in
                        Self.device(device, access: MacScreenAccess(hub.scope(host: device.id, viewer: hub.identity.id)),
                                    hubConnected: hub.connection == .connected,
                                    setup: source.setup.row(id: device.id, isMac: device.platform != .ios, online: device.online))
                    })
                }
                // This Mac is drawn whenever signed in: before this device is registered, the switch waits and
                // says why. Gating the section on registration hid it (and its permissions) for as long as the
                // hub was unreachable (run 45954248647: socket connect timeouts, no This Mac section).
                let registered = hub.thisDevice != nil || hub.status == .ready
                let hubHost = source.hubHost
                sharing = Sharing(isSharing: hubHost.isSharing, busy: hubHost.busy || !registered,
                                  screenRecordingGranted: home.host.screenRecordingGranted,
                                  accessibilityGranted: home.host.accessibilityGranted,
                                  session: hubHost.session, lastError: hubHost.lastError,
                                  showFirstUse: Self.showsFirstUse(store: source.store, isSharing: hubHost.isSharing),
                                  hubNote: registered ? nil : Self.hubNote(hub.status))
            } else {
                devices = source.box.startupMessage.map(Devices.note) ?? Self.setupDevices(configured: source.box.configured,
                                                                                               restoring: source.box.restoring || source.box.connecting)
            }
        }
        if let shortcuts = home.systemShortcuts {
            keyboard = Keyboard(enabled: shortcuts.enabled, needsAccessibility: shortcuts.needsAccessibility)
        }
    }

    /// What Your Devices says with no row to list (`DeviceDiscovery`, Rust's rule): "none" only after a
    /// device-list read succeeded; before it, loading; a failure says why, never "none" (ask-6a79af928f).
    static func emptyNote(_ discovery: DeviceDiscovery) -> String {
        switch discovery {
        case .noDevices:
            return L.t("macScreen.home.noSharedDevices", "None of your other devices share Mac Screen. On the Mac you want to see, turn on Allow Mac Screen on this Mac.")
        case .list, .finding:
            return L.t("macScreen.home.devicesLoading", "Loading your devices…")
        case let .failed(reason, detail):
            return reason.words(detail: detail)
        }
    }

    /// What This Mac says while this device is not on the hub yet: connecting, or why it could not register.
    static func hubNote(_ status: DeviceHub.Status) -> String {
        if case let .failed(reason) = status {
            return L.t("macScreen.home.thisMacHubFailed", "This Mac could not reach the device hub: \(reason). cmux keeps trying.")
        }
        return L.t("macScreen.home.thisMacJoining", "Connecting this Mac to the device hub…")
    }

    /// One hub device as the page shows it.
    static func device(_ device: HubDevice, access: MacScreenAccess, hubConnected: Bool,
                       setup: MacScreenDeviceSetupRow = .none) -> Device {
        Device(id: device.id, name: device.name, isPhone: device.platform == .ios, online: device.online,
               macScreenShared: device.macScreenShared, access: access, onlineKnown: hubConnected, setup: setup,
               platform: device.platform)
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
    /// (Settings › Development) must be valid when set. While the saved
    /// sign-in restores, it is loading: neither signed out nor a bad address.
    static func setupDevices(configured: Bool, restoring: Bool = false) -> Devices {
        guard configured else {
            return .note(L.t("macScreen.home.invalidHubAddress", "Mac Screen works through the device hub. The Device Hub Address in Settings › Development is not a valid web address; fix it, or clear it to use the built-in hub."))
        }
        if restoring { return .note(L.t("macScreen.home.devicesLoading", "Loading your devices…")) }
        return .signedOut(L.t("macScreen.home.devicesSignIn", "Sign in to cmux to see your other Macs here."))
    }
}

/// The home page's Your Devices section: the user's other devices that
/// share Mac Screen, online state and this Mac's access to each, Connect
/// with View Only or Full Control, Change Access. Allow Mac Screen on This
/// Mac is in `MacScreenHomeView+Sharing.swift`.
extension MacScreenHomeView {
    // MARK: Your Devices

    func yourDevices(_ devices: MacScreenHomeSnapshot.Devices, look: MacScreenDevicesLook = .quiet,
                     placement: MacScreenSetupPlacement = .standard) -> NSView {
        let content: NSView
        switch devices {
        case let .note(text):
            content = MacScreenHomeParts.note(text)
        case let .signedOut(text):
            let signIn = SignInButton { [weak self] in self?.actions.signIn() }
            signIn.setAccessibilityIdentifier("macScreen.home.signIn")
            content = MacScreenStack.make(.vertical, spacing: 8, alignment: .leading, [MacScreenHomeParts.note(text), signIn.withBackendLine(actions.signInBackend)])
        case let .list(list):
            let rows = MacScreenStack.make(.vertical, spacing: 0, alignment: .leading)
            let views = look == .classic ? list.map { classicRow($0, placement: placement) } : quietRows(list, look: look)
            for (index, view) in views.enumerated() {
                MacScreenStack.addFullWidth(view, to: rows)
                if index < views.count - 1, colors.borders { MacScreenStack.addFullWidth(rowSeparator(), to: rows) }
            }
            content = rows
        }
        return MacScreenHomeParts.section(L.t("macScreen.home.yourDevices", "Your Devices"), content: content)
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
        /// Online, and a screen this Mac cannot open yet (a Windows PC): one word, no buttons.
        case notViewable
        /// Offline: the name alone, dim.
        case offline
    }

    static func rowState(_ device: MacScreenHomeSnapshot.Device) -> RowState {
        // Offline counts only while this Mac's hub link is up; until then the hub's word may be stale and the
        // row stays openable (the pane's Connect card says what it finds).
        guard device.online || !device.onlineKnown else { return .offline }
        if !device.viewable { return .notViewable }
        if !device.access.allowsRequests { return .blocked }
        return device.macScreenShared ? .usable : .sharingOff
    }

    /// Viewable Macs first, then online ones that are not, then offline ones (folded, listed or counted by `look`).
    private func quietRows(_ list: [MacScreenHomeSnapshot.Device], look: MacScreenDevicesLook) -> [NSView] {
        let order: [RowState] = [.usable, .sharingOff, .blocked, .notViewable]
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
        let glyph = MacScreenGlyph(device.glyph, font: MacScreenType.glyph,
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
        // Set Up cmux sits in the More menu, and Start cmux on NAME is an offline row's one button: the only
        // thing that row can do now. A blocked row gets neither (`blocking`), a sharing-off row stays one word.
        let setup = device.setup.blocking(allowsRequests: device.access.allowsRequests)
        switch state {
        case .usable:
            views.append(MacScreenButton(L.t("macScreen.hub.view", "View Only"), id: "macScreen.home.view.\(device.name)") { [weak self] in
                self?.actions.openDevice(id, .view)
            })
            views.append(MacScreenButton(L.t("macScreen.hub.control", "Full Control"), role: .primary, id: "macScreen.home.control.\(device.name)") { [weak self] in
                self?.actions.openDevice(id, .full)
            })
            let more = MacScreenMenuButton(symbol: "ellipsis.circle", accessibilityTitle: nil, id: "macScreen.home.more.\(device.name)")
            let setupDevice = setup.showsSetup ? device : nil
            more.makeMenu = { [weak self] in self?.moreMenu(id, setup: setupDevice) ?? NSMenu() }
            views.append(more)
        case .sharingOff, .blocked:
            let word = state == .blocked ? L.t("macScreen.home.blockedShort", "Not allowed")
                : L.t("macScreen.home.sharingOff", "Sharing off")
            let reason = MacScreenText(word, font: MacScreenType.caption, ink: \.secondary)
            reason.setContentCompressionResistancePriority(.required, for: .horizontal)
            reason.setAccessibilityIdentifier("macScreen.home.\(state == .blocked ? "blocked" : "notShared").\(device.name)")
            views.append(reason)
            // One step its host takes, not just a grey word (Leo, 2026-11-18: "idk why that was greyed").
            let fix: ScreenPicker.Fix = state == .blocked ? .deviceAccess : .shareThisMac
            let host = device.name
            views.append(MacScreenButton(L.t("macScreen.guide.setUp", "Set Up…"), compact: true, id: "macScreen.home.setUp.\(device.name)") { [weak self] in
                guard let self, let hub = devices?.box.hub else { return }
                let thisMac = MacScreenHostSetupGuide.ThisMac(id: hub.identity.id, name: hub.thisDevice?.name ?? hub.deviceName)
                MacScreenHostSetupGuide(host: host, fix: fix, thisMac: thisMac).present(in: window)
            })
        case .notViewable:
            views.append(notViewableWord(device))
        case .offline:
            if setup.showsStart { views.append(startButton(device, compact: true)) }
        }
        let vertical: CGFloat = offline ? 6 : 10
        let stack = MacScreenStack.make(.horizontal, spacing: 10, alignment: .centerY, views,
                                        insets: NSEdgeInsets(top: vertical, left: 14, bottom: vertical, right: 14))
        // A run's checklist goes under the row, from the name's edge (the separators' inset).
        let body = MacScreenStack.make(.vertical, spacing: 0, alignment: .leading)
        MacScreenStack.addFullWidth(stack, to: body)
        if let run = setup.run {
            let list = setupChecklist(run, device: device)
            let inset = MacScreenStack.make(.vertical, spacing: 0, alignment: .leading, [list],
                                            insets: NSEdgeInsets(top: 0, left: 50, bottom: 12, right: 14))
            list.widthAnchor.constraint(equalTo: inset.widthAnchor, constant: -64).isActive = true
            MacScreenStack.addFullWidth(inset, to: body)
        }
        let row = MacScreenRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            body.topAnchor.constraint(equalTo: row.topAnchor),
            body.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        if state == .usable { row.onDoubleClick = { [weak self] in self?.actions.openDevice(id, nil) } }
        return row
    }

    /// The quiet look's one row for every offline Mac: a chevron, "Offline" and the count; a click opens it.
    private func offlineGroupRow(count: Int) -> NSView {
        let toggle: () -> Void = { [weak self] in
            guard let self else { return }
            offlineExpanded.toggle()
            if let built { build(built) }
        }
        // A MacScreenButton draws its symbol or its title, never both: the chevron sits in the rows' glyph
        // column and the title beside it, so "Offline (N)" lines up with the Macs' names.
        let chevron = MacScreenButton("", role: .icon, symbol: offlineExpanded ? "chevron.down" : "chevron.right",
                                      id: "macScreen.home.offlineChevron", action: toggle)
        chevron.setAccessibilityElement(false)
        chevron.widthAnchor.constraint(equalToConstant: 26).isActive = true
        let label = MacScreenButton(String(format: L.t("macScreen.home.offlineGroup", "Offline (%d)"), count), role: .icon,
                                    id: "macScreen.home.offlineGroup", action: toggle)
        label.setAccessibilityValue(offlineExpanded ? "expanded" : "collapsed")
        return MacScreenStack.make(.horizontal, spacing: 6, alignment: .centerY, [chevron, label, MacScreenSpacer()],
                                   insets: NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14))
    }

    // MARK: Classic rows (Debug Settings `macScreen.devicesLook` = classic)

    private func classicRow(_ device: MacScreenHomeSnapshot.Device, placement: MacScreenSetupPlacement) -> NSView {
        let glyph = MacScreenGlyph(device.glyph, font: MacScreenType.glyph, width: 26)
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
        let setup = device.setup.blocking(allowsRequests: device.access.allowsRequests)
        // Start cmux is the one button that can work while the Mac is offline: it is the row's default
        // button then, and Full Control steps down to a plain one (one primary per row).
        let startShows = setup.showsStart && placement != .below
        if placement == .below, setup.showsStart || setup.showsSetup {
            var line: [NSView] = []
            if setup.showsStart { line.append(startButton(device, compact: true)) }
            if setup.showsSetup { line.append(setupButton(device, compact: true)) }
            labels.setCustomSpacing(8, after: labelViews[labelViews.count - 1])
            labels.addArrangedSubview(MacScreenStack.make(.horizontal, spacing: 8, alignment: .centerY, line))
        }
        // Set Up cmux in the More menu (the standard placement); a row that can't connect has a More menu
        // with only that item.
        let menuSetup = placement == .standard && setup.showsSetup
        var views: [NSView] = [glyph, labels, MacScreenSpacer()]
        if placement == .buttons, setup.showsSetup { views.append(setupButton(device, compact: false)) }
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
        if startShows, !device.access.allowsRequests { views.append(startButton(device, compact: false)) }
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
            views.append(MacScreenButton(L.t("macScreen.hub.control", "Full Control"), role: startShows ? .plain : .primary,
                                         id: "macScreen.home.control.\(device.name)") { [weak self] in
                self?.actions.openDevice(id, .full)
            })
            if startShows { views.append(startButton(device, compact: false)) }
            let more = MacScreenMenuButton(symbol: "ellipsis.circle", accessibilityTitle: nil, id: "macScreen.home.more.\(device.name)")
            more.makeMenu = { [weak self] in self?.moreMenu(id, setup: menuSetup ? device : nil) ?? NSMenu() }
            views.append(more)
        } else {
            if device.access.allowsRequests {
                let view = MacScreenButton(L.t("macScreen.hub.view", "View Only"), id: "macScreen.home.view.\(device.name)") {}
                view.isEnabled = false
                let control = MacScreenButton(L.t("macScreen.hub.control", "Full Control"), role: startShows ? .plain : .primary,
                                              id: "macScreen.home.control.\(device.name)") {}
                control.isEnabled = false
                views.append(view)
                views.append(control)
                if startShows { views.append(startButton(device, compact: false)) }
            }
            if menuSetup {
                let more = MacScreenMenuButton(symbol: "ellipsis.circle", accessibilityTitle: nil, id: "macScreen.home.more.\(device.name)")
                more.makeMenu = { [weak self] in self?.setupMenu(device) ?? NSMenu() }
                views.append(more)
            }
        }
        let stack = MacScreenStack.make(.horizontal, spacing: 12, alignment: .centerY, views,
                                        insets: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))
        // The run's checklist goes under the row, from the name's edge (the separators' inset).
        let body = MacScreenStack.make(.vertical, spacing: 0, alignment: .leading)
        MacScreenStack.addFullWidth(stack, to: body)
        if let run = setup.run {
            let list = setupChecklist(run, device: device)
            let inset = MacScreenStack.make(.vertical, spacing: 0, alignment: .leading, [list],
                                            insets: NSEdgeInsets(top: 0, left: 50, bottom: 12, right: 14))
            list.widthAnchor.constraint(equalTo: inset.widthAnchor, constant: -64).isActive = true
            MacScreenStack.addFullWidth(inset, to: body)
        }
        let row = MacScreenRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            body.topAnchor.constraint(equalTo: row.topAnchor),
            body.bottomAnchor.constraint(equalTo: row.bottomAnchor),
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
    private func moreMenu(_ id: String, setup device: MacScreenHomeSnapshot.Device? = nil) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let device {
            menu.addItem(setupMenuItem(device))
            menu.addItem(.separator())
        }
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

    /// The More menu of a row that can't connect: Set Up cmux only.
    private func setupMenu(_ device: MacScreenHomeSnapshot.Device) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(setupMenuItem(device))
        return menu
    }

    private func setupMenuItem(_ device: MacScreenHomeSnapshot.Device) -> NSMenuItem {
        let item = NSMenuItem.macScreen(L.t("macScreen.setup.setUp", "Set Up cmux")) { [weak self] in
            self?.devices?.setup.run(.setup, id: device.id, name: device.name)
        }
        item.isEnabled = device.setup.canRun(.setup)
        return item
    }

    // MARK: Set up cmux, Start cmux

    /// Start cmux on NAME: the row's default button while the Mac is offline (and while it starts).
    private func startButton(_ device: MacScreenHomeSnapshot.Device, compact: Bool) -> MacScreenButton {
        let button = MacScreenButton(MacScreenSetupChecklist.startTitle(device.name), role: .primary, compact: compact,
                                     id: "macScreen.home.start.\(device.name)") { [weak self] in
            self?.devices?.setup.run(.start, id: device.id, name: device.name)
        }
        button.isEnabled = device.setup.canRun(.start)
        return button
    }

    /// Set Up cmux as a button (the placements that do not keep it in the More menu).
    private func setupButton(_ device: MacScreenHomeSnapshot.Device, compact: Bool) -> MacScreenButton {
        let button = MacScreenButton(L.t("macScreen.setup.setUp", "Set Up cmux"), compact: compact,
                                     id: "macScreen.home.setUp.\(device.name)") { [weak self] in
            self?.devices?.setup.run(.setup, id: device.id, name: device.name)
        }
        button.isEnabled = device.setup.canRun(.setup)
        return button
    }

    private func setupChecklist(_ run: MacScreenDeviceRun, device: MacScreenHomeSnapshot.Device) -> NSView {
        MacScreenSetupChecklist.make(run, name: device.name, id: "macScreen.home.setupSteps.\(device.name)") { [weak self] in
            self?.devices?.setup.dismiss(id: device.id)
        }
    }
}

/// Where a Mac's row puts Set Up cmux and Start cmux on NAME. The page draws ``standard``; the
/// Screen Sharing gallery draws every one (`AAMacScreenSharingGalleryTests`).
enum MacScreenSetupPlacement: String, CaseIterable {
    /// Start in the row's buttons, as its default button while the Mac is offline; Set Up cmux in
    /// the More menu.
    case standard
    /// Both as small buttons on a line under the name and status, the row's buttons as they were.
    case below
    /// Both in the row's buttons: Set Up cmux plain, Start the default button while offline.
    case buttons
}

/// Why Your Devices (and Settings › Devices) cannot list, in words: the reason, then the hub's own words.
extension DeviceDiscovery.Reason {
    func words(detail: String?) -> String {
        let text = switch self {
        case .hub, .connection, .replaced:
            L.t("macScreen.home.listFailed.hub", "Can’t reach the device hub, so your other Macs can’t be listed yet. cmux keeps trying.")
        case .list:
            L.t("macScreen.home.listFailed.list", "Couldn’t load your devices. cmux tries again when the hub reconnects.")
        case .removed, .signedOut:
            L.t("devices.status.removed", "This Mac left your devices.")
        }
        guard let detail, !detail.isEmpty else { return text }
        return text + " (" + detail + ")"
    }
}

import AppKit
import CmuxNextDesign
import CmuxNextDevices

/// The home page's Your Devices section: one row per physical device (``HubDeviceList``), its platform's
/// glyph, its name and whether it is online, and ONE action, Connect (Full Control); View Only, new tabs and
/// the device's own switch for this Mac are in its menu. A device that can't connect says why in a line that
/// wraps, never a disabled button (Leo 2026-11-15: "it's too many fucking steps"). Drawn in the look Debug
/// Settings picks (`MacScreenDevicesLook`). This Mac's section is in `MacScreenHomeView+Sharing.swift`.
extension MacScreenHomeView {
    // MARK: Your Devices

    func yourDevices(_ devices: MacScreenHomeSnapshot.Devices, look: MacScreenDevicesLook = .connect) -> NSView {
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
            if look == .grouped {
                let online = list.filter(\.reachable), offline = list.filter { !$0.reachable }
                addRows(online, look: look, to: rows)
                if !offline.isEmpty {
                    if !online.isEmpty { MacScreenStack.addFullWidth(MacScreenFill.divider(), to: rows) }
                    let header = MacScreenStack.make(.vertical, spacing: 0, alignment: .leading,
                                                     insets: NSEdgeInsets(top: 10, left: 14, bottom: 0, right: 14))
                    header.addArrangedSubview(MacScreenText(L.t("macScreen.home.offline", "Offline"), font: MacScreenType.caption, ink: \.secondary))
                    MacScreenStack.addFullWidth(header, to: rows)
                    addRows(offline, look: look, to: rows)
                }
            } else {
                addRows(list, look: look, to: rows)
            }
            content = rows
        }
        return MacScreenHomeParts.section(L.t("macScreen.home.yourDevices", "Your Devices"), content: content)
    }

    private func addRows(_ list: [MacScreenHomeSnapshot.Device], look: MacScreenDevicesLook, to rows: NSStackView) {
        for device in list {
            MacScreenStack.addFullWidth(deviceRow(device, look: look), to: rows)
            guard device.id != list.last?.id, colors.borders else { continue }
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

    /// The SF Symbol for a device's platform (Windows and Linux rows come from the hub's platform, never made up).
    static func glyph(_ platform: DevicePlatform?) -> String {
        switch platform?.rawValue {
        case "ios": "iphone"
        case "linux": "server.rack"
        case "windows": "pc"
        default: "desktopcomputer"
        }
    }

    /// Why `device` can't connect, and the id of the line that says it: offline first, then a host that blocks
    /// this Mac (the hub refuses without a prompt, so turning sharing on would not help), then sharing off.
    static func unavailable(_ device: MacScreenHomeSnapshot.Device) -> (text: String, id: String)? {
        if !device.reachable {
            return (String(format: L.t("macScreen.home.offlineDetail", "Open cmux on %@ to share its screen."), device.name), "offline")
        }
        if !device.access.allowsRequests {
            return (String(format: L.t("macScreen.home.blocked", "%1$@ doesn’t allow this Mac. Change it on %2$@ in Settings › Devices."),
                           device.name, device.name), "blocked")
        }
        if !device.macScreenShared {
            return (String(format: L.t("macScreen.home.sharingOffDetail", "Screen sharing is off on %@."), device.name), "notShared")
        }
        return nil
    }

    /// The status line: online, or offline with when it was last seen.
    static func presence(_ device: MacScreenHomeSnapshot.Device) -> String {
        if device.reachable { return L.t("macScreen.home.online", "Online") }
        guard let seen = device.lastSeen else { return L.t("macScreen.home.offline", "Offline") }
        return String(format: L.t("devices.offlineSeen", "Offline · seen %@"), seen.formatted(.relative(presentation: .named)))
    }

    private func deviceRow(_ device: MacScreenHomeSnapshot.Device, look: MacScreenDevicesLook) -> NSView {
        let glyph = MacScreenGlyph(Self.glyph(device.platform), font: MacScreenType.glyph,
                                   ink: device.reachable ? \.secondary : \.tertiary, width: 26)
        let name = MacScreenText(device.name, font: MacScreenType.emphasized, wraps: true)
        let status = MacScreenStack.make(.horizontal, spacing: 6, alignment: .centerY, [
            MacScreenFill.dot(device.reachable ? \.success : \.tertiary, side: 7),
            MacScreenText(Self.presence(device), font: MacScreenType.caption, ink: \.secondary),
        ])
        let labels = MacScreenStack.make(.vertical, spacing: 2, alignment: .leading)
        MacScreenStack.addFullWidth(name, to: labels)
        labels.addArrangedSubview(status)
        if let unavailable = Self.unavailable(device) {
            // A whole sentence that wraps under the name: never cut off mid-sentence.
            let reason = MacScreenText(unavailable.text, font: MacScreenType.caption, ink: \.secondary, wraps: true)
            reason.setAccessibilityIdentifier("macScreen.home.\(unavailable.id).\(device.name)")
            MacScreenStack.addFullWidth(reason, to: labels)
        }
        labels.setContentHuggingPriority(.init(1), for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [glyph, labels]
        if device.connectable { views.append(connectControl(device, look: look)) }
        let stack = MacScreenStack.make(.horizontal, spacing: 12, alignment: .centerY, views,
                                        insets: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))
        let row = MacScreenRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setAccessibilityIdentifier("macScreen.home.device.\(device.name)")
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            stack.topAnchor.constraint(equalTo: row.topAnchor),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            // The labels keep the row's 10-point padding above and below them (a centered stack alone sizes
            // the row to its button and lets the lines run into the padding).
            labels.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 10),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -10),
        ])
        if device.connectable {
            let id = device.id
            row.onDoubleClick = { [weak self] in self?.actions.openDevice(id, .full) }
        }
        return row
    }

    /// Connect (Full Control) and the row's menu: a More (…) button after it, or its chevron joined to it.
    private func connectControl(_ device: MacScreenHomeSnapshot.Device, look: MacScreenDevicesLook) -> NSView {
        let id = device.id
        let connect = MacScreenButton(L.t("macScreen.home.connect", "Connect"), role: .primary,
                                      id: "macScreen.home.connect.\(device.name)") { [weak self] in
            self?.actions.openDevice(id, .full)
        }
        let more = MacScreenMenuButton(symbol: look == .split ? "chevron.down" : "ellipsis.circle",
                                       accessibilityTitle: L.t("macScreen.home.moreActions", "More Actions"),
                                       id: "macScreen.home.more.\(device.name)")
        more.makeMenu = { [weak self] in self?.moreMenu(device) ?? NSMenu() }
        return MacScreenStack.make(.horizontal, spacing: look == .split ? 4 : 8, alignment: .centerY, [connect, more])
    }

    /// The row's menu: View Only, both in a new tab, and the device's own switch for this Mac when it is known.
    func moreMenu(_ device: MacScreenHomeSnapshot.Device) -> NSMenu {
        let id = device.id, name = device.name
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem.macScreen(L.t("macScreen.hub.view", "View Only")) { [weak self] in self?.actions.openDevice(id, .view) })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.macScreen(L.t("macScreen.home.connectNewTab", "Connect in New Tab")) { [weak self] in
            self?.actions.openDeviceInNewTab(id, .full)
        })
        menu.addItem(NSMenuItem.macScreen(L.t("macScreen.home.openViewNewTab", "View Only in New Tab")) { [weak self] in
            self?.actions.openDeviceInNewTab(id, .view)
        })
        if let allows = device.allowsThisMac, let remote = actions.remoteAccess {
            menu.addItem(.separator())
            // One switch per device: off stops this Mac connecting to it; the own-device grant turns it on.
            menu.addItem(NSMenuItem.macScreen(L.t("macScreen.home.allowSharingMenu", "Allow Screen Sharing"), checked: allows) {
                remote.set(id, name, !allows)
            })
        }
        return menu
    }
}

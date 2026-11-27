import AppKit
import CmuxNextDesign

/// What Allow Mac Screen on This Mac says about this Mac now, from its permissions and session: Rust's
/// `homeSharing.status` decides; Swift puts the words in this person's language.
extension MacScreenHomeSnapshot.Sharing {
    /// Rust's answer for this sharing state.
    var rdStatus: [String: Any] {
        RdUI.call("homeSharing.status", [
            "session": MacScreenHomeView.rd(session), "screenRecordingGranted": screenRecordingGranted,
            "accessibilityGranted": accessibilityGranted, "isSharing": isSharing, "busy": busy,
        ]) as? [String: Any] ?? [:]
    }

    /// The status line: who is connected, else what the permissions let a device do.
    var statusText: String { MacScreenHomeView.text(rdStatus["statusText"], session) }

    /// The status dot's ink: lit while a viewer is connected, attention while no device can see this Mac.
    var statusInk: KeyPath<MacScreenColors, NSColor> { MacScreenHomeView.ink(rdStatus["statusInk"]) }
}

/// Allow Mac Screen on This Mac: the switch, its permissions and who is connected, in the look
/// Debug Settings picks (`MacScreenSharingLook`).
extension MacScreenHomeView {
    /// The width of the leading glyph column the list rows share (the permission glyphs and the status dot).
    private static let glyphColumn: CGFloat = 18
    /// A list row's padding.
    private static let rowInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

    func sharingSection(_ sharing: MacScreenHomeSnapshot.Sharing,
                        look: MacScreenSharingLook = MacScreenTunables.sharingLook.value) -> NSView {
        switch look {
        case .simple: simpleSharing(sharing)
        case .classic: classicSharing(sharing)
        case .list: listSharing(sharing)
        case .summary: summarySharing(sharing)
        case .status: statusSharing(sharing)
        }
    }

    // MARK: Simple (default)

    /// The switch, whose detail is the status; who is connected, with one Stop, while a device is; and the
    /// macOS permissions as one Grant Access step while one is missing (Leo 2026-11-16: the allow and deny
    /// rows were "too many ... steps").
    private func simpleSharing(_ sharing: MacScreenHomeSnapshot.Sharing) -> NSView {
        let content = MacScreenStack.make(.vertical, spacing: 0, alignment: .leading)
        let status = sharing.rdStatus
        let detail = Self.text(status["simpleDetail"], sharing.session)
        add(padded(sharingSwitch(sharing, title: L.t("macScreen.home.allowToggleShort", "Allow Mac Screen"), detail: detail)), to: content)
        if let session = sharing.session, let connected = status["connected"] as? [String: Any] {
            add(MacScreenFill.divider(), to: content, inset: Self.rowInsets.left)
            add(padded(connectedRow(session, connected)), to: content)
        }
        if let grant = (status["grant"] as? [String: Any]).map({ grantRow(sharing, $0) }) {
            add(MacScreenFill.divider(), to: content, inset: Self.rowInsets.left)
            add(padded(grant), to: content)
        }
        if let error = sharing.lastError { add(padded(errorRow(error)), to: content) }
        return MacScreenHomeParts.section(L.t("devices.section.this", "This Mac"), content: content)
    }

    /// "Connected: Studio · Viewing" with one Stop, while a device is connected or connecting.
    private func connectedRow(_ session: MacScreenHubHost.Session, _ connected: [String: Any]) -> NSView {
        let label = MacScreenText(Self.text(connected["text"], session), font: MacScreenType.body, wraps: true)
        label.setAccessibilityIdentifier("macScreen.home.connected")
        label.setContentHuggingPriority(.init(1), for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let hubHost = devices?.hubHost
        let stop = MacScreenButton(L.t("macScreen.home.stopSession", "Stop"), role: .destructive, compact: true,
                                   id: "macScreen.home.stop") { _ = hubHost?.stopSession() }
        return MacScreenStack.make(.horizontal, spacing: 10, alignment: .centerY, [
            glyphCell(MacScreenFill.dot(Self.ink(connected["ink"]), side: 8)), label, stop,
        ])
    }

    /// The macOS permissions as one step: one row, one Grant Access button that asks macOS for the first one
    /// missing (Screen Recording, then Accessibility) through the share host, so the helper that holds the
    /// grant is the one asked. `grant`: Rust's answer, absent when both are granted.
    private func grantRow(_ sharing: MacScreenHomeSnapshot.Sharing, _ grant: [String: Any]) -> NSView {
        let screenRecording = grant["request"] as? String == "screenRecording"
        let title = Self.text(grant["title"], sharing.session)
        let detail = Self.text(grant["detail"], sharing.session)
        let labels = MacScreenStack.make(.vertical, spacing: 2, alignment: .leading)
        MacScreenStack.addFullWidth(MacScreenText(title, font: MacScreenType.body, wraps: true), to: labels)
        MacScreenStack.addFullWidth(MacScreenText(detail, font: MacScreenType.caption, ink: \.secondary, wraps: true), to: labels)
        labels.setContentHuggingPriority(.init(1), for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let host = self.host
        let grant = MacScreenButton(L.t("macScreen.home.grantAccess", "Grant Access"), role: .primary, compact: true,
                                    id: "macScreen.home.grantAccess") {
            if screenRecording { host.requestScreenRecording() } else { host.requestAccessibility() }
        }
        let row = MacScreenStack.make(.horizontal, spacing: 10, alignment: .centerY, [glyphCell(permissionGlyph(granted: false)), labels, grant])
        row.setAccessibilityIdentifier("macScreen.home.grant")
        return row
    }

    // MARK: List

    private func listSharing(_ sharing: MacScreenHomeSnapshot.Sharing) -> NSView {
        let content = MacScreenStack.make(.vertical, spacing: 0, alignment: .leading)
        add(padded(sharingSwitch(sharing, title: L.t("macScreen.home.allowToggleShort", "Allow Mac Screen"))), to: content)
        if sharing.isSharing {
            for row in permissionRows(sharing) {
                add(MacScreenFill.divider(), to: content, inset: Self.rowInsets.left)
                add(padded(row), to: content)
            }
            add(MacScreenFill.divider(), to: content, inset: Self.rowInsets.left)
            add(padded(statusRow(sharing)), to: content)
        }
        if let error = sharing.lastError { add(padded(errorRow(error)), to: content) }
        return MacScreenHomeParts.section(L.t("devices.section.this", "This Mac"), content: content)
    }

    // MARK: Summary

    private func summarySharing(_ sharing: MacScreenHomeSnapshot.Sharing) -> NSView {
        let content = MacScreenStack.make(.vertical, spacing: 0, alignment: .leading)
        add(padded(sharingSwitch(sharing, title: L.t("macScreen.home.allowToggleShort", "Allow Mac Screen"))), to: content)
        if sharing.isSharing {
            add(MacScreenFill.divider(), to: content, inset: Self.rowInsets.left)
            add(padded(permissionSummary(sharing)), to: content)
            add(MacScreenFill.divider(), to: content, inset: Self.rowInsets.left)
            add(padded(statusRow(sharing, glyphColumn: false)), to: content)
        }
        if let error = sharing.lastError { add(padded(errorRow(error)), to: content) }
        return MacScreenHomeParts.section(L.t("devices.section.this", "This Mac"), content: content)
    }

    /// Both permissions on one line, each a glyph and its name; one button opens the first missing one.
    private func permissionSummary(_ sharing: MacScreenHomeSnapshot.Sharing) -> NSView {
        func item(_ title: String, granted: Bool) -> NSView {
            MacScreenStack.make(.horizontal, spacing: 5, alignment: .centerY, [
                permissionGlyph(granted: granted),
                MacScreenText(title, font: MacScreenType.body, ink: granted ? \.secondary : \.primary),
            ])
        }
        var views: [NSView] = [
            item(L.t("macScreen.home.screenRecording", "Screen Recording"), granted: sharing.screenRecordingGranted),
            item(L.t("macScreen.home.accessibility", "Accessibility"), granted: sharing.accessibilityGranted),
            MacScreenSpacer(),
        ]
        if let open = sharing.rdStatus["openSettings"] as? String {
            let screenRecording = open == "screenRecording"
            views.append(MacScreenButton(L.t("macScreen.home.openSettings", "Open System Settings"), compact: true) { [weak self] in
                self?.host.openSettings(screenRecording: screenRecording)
            })
        } else {
            views.append(MacScreenText(L.t("macScreen.home.granted", "Allowed"), font: MacScreenType.caption, ink: \.secondary))
        }
        let row = MacScreenStack.make(.horizontal, spacing: 14, alignment: .centerY, views)
        row.setAccessibilityIdentifier("macScreen.home.permissions")
        return row
    }

    // MARK: Status first

    private func statusSharing(_ sharing: MacScreenHomeSnapshot.Sharing) -> NSView {
        let content = MacScreenStack.make(.vertical, spacing: 0, alignment: .leading)
        let title = Self.text(sharing.rdStatus["statusTitle"], sharing.session)
        let toggle = sharingSwitch(sharing, title: title, emphasized: sharing.isSharing)
        if sharing.isSharing {
            let row = MacScreenStack.make(.horizontal, spacing: 10, alignment: .centerY, [glyphCell(MacScreenFill.dot(sharing.statusInk, side: 8)), toggle])
            add(padded(row), to: content)
            if let session = sharing.session {
                let buttons = MacScreenStack.make(.horizontal, spacing: 0, alignment: .centerY, [MacScreenSpacer(), sessionButtons(session)])
                add(padded(buttons), to: content)
            }
            for row in permissionRows(sharing) {
                add(MacScreenFill.divider(), to: content, inset: Self.rowInsets.left)
                add(padded(row), to: content)
            }
        } else {
            add(padded(toggle), to: content)
        }
        if let error = sharing.lastError { add(padded(errorRow(error)), to: content) }
        return MacScreenHomeParts.section(L.t("devices.section.this", "This Mac"), content: content)
    }

    // MARK: Classic

    private func classicSharing(_ sharing: MacScreenHomeSnapshot.Sharing) -> NSView {
        let content = MacScreenHomeParts.cardColumn()
        let toggle = sharingSwitch(sharing, title: L.t("macScreen.home.allowToggle", "Allow Mac Screen on this Mac"),
                                   detail: L.t("macScreen.home.allowDetail", "Your other devices signed in to this cmux account can ask to see or control this Mac. You approve each device, or choose its access in Settings › Devices."))
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
            let status = MacScreenText(sharing.statusText, font: MacScreenType.body)
            status.setAccessibilityIdentifier("macScreen.home.hubStatus")
            status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            var views: [NSView] = [MacScreenFill.dot(sharing.statusInk, side: 8), status, MacScreenSpacer()]
            if let session = sharing.session { views.append(sessionButtons(session)) }
            MacScreenStack.addFullWidth(MacScreenStack.make(.horizontal, spacing: 8, alignment: .centerY, views), to: content)
        }
        if let error = sharing.lastError { MacScreenStack.addFullWidth(errorRow(error), to: content) }
        return MacScreenHomeParts.section(L.t("macScreen.home.allowTitle", "Allow Mac Screen on This Mac"), content: content)
    }

    // MARK: Rows

    /// The Allow Mac Screen switch; it shows the hub's record, not the click.
    private func sharingSwitch(_ sharing: MacScreenHomeSnapshot.Sharing, title: String, emphasized: Bool = false,
                               detail: String = L.t("macScreen.home.shareThisMacOn", "Your devices on this account can connect.")) -> NSView {
        let hubHost = devices?.hubHost
        return MacScreenHomeParts.switchRow(
            title: title, detail: detail, isOn: sharing.isSharing, enabled: !sharing.busy, emphasized: emphasized,
            id: "macScreen.home.allowToggle"
        ) { [weak self] on in
            if on {
                self?.actions.shareThisMac()
            } else {
                // The person's click: their off outranks the join default (Z4).
                CmuxRemoteShareConsent.recordDecline()
                hubHost?.stopSession(immediately: true)
                // task-owner: one sharing-off write; the switch follows the hub's record
                Task { try? await hubHost?.setSharing(false) }
            }
            // The switch shows the hub's record: back to it if the write does not change it.
            self?.syncSwitchesSoon()
        }
    }

    /// Screen Recording and Accessibility as list rows: a glyph in the shared column, the name, and
    /// Allowed or a button. The detail says what the permission is for only while it is missing.
    private func permissionRows(_ sharing: MacScreenHomeSnapshot.Sharing) -> [NSView] {
        [
            permissionRow(title: L.t("macScreen.home.screenRecording", "Screen Recording"),
                          missing: L.t("macScreen.home.screenRecordingNeeded", "Needed to send this screen. macOS may ask you to reopen cmux."),
                          granted: sharing.screenRecordingGranted, id: "macScreen.home.screenRecording") { [weak self] in
                self?.host.openSettings(screenRecording: true)
            },
            permissionRow(title: L.t("macScreen.home.accessibility", "Accessibility"),
                          missing: L.t("macScreen.home.accessibilityNeeded", "Needed for clicks and typing. Without it, devices can only watch."),
                          granted: sharing.accessibilityGranted, id: "macScreen.home.accessibility") { [weak self] in
                self?.host.openSettings(screenRecording: false)
            },
        ]
    }

    private func permissionRow(title: String, missing: String, granted: Bool, id: String, open: @escaping () -> Void) -> NSView {
        let labels = MacScreenStack.make(.vertical, spacing: 2, alignment: .leading)
        MacScreenStack.addFullWidth(MacScreenText(title, font: MacScreenType.body, wraps: true), to: labels)
        if !granted {
            MacScreenStack.addFullWidth(MacScreenText(missing, font: MacScreenType.caption, ink: \.secondary, wraps: true), to: labels)
        }
        labels.setContentHuggingPriority(.init(1), for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let trailing: NSView = granted
            ? MacScreenText(L.t("macScreen.home.granted", "Allowed"), font: MacScreenType.body, ink: \.secondary)
            : MacScreenButton(L.t("macScreen.home.openSettings", "Open System Settings"), compact: true, action: open)
        let row = MacScreenStack.make(.horizontal, spacing: 10, alignment: .centerY, [glyphCell(permissionGlyph(granted: granted)), labels, trailing])
        row.setAccessibilityIdentifier(id)
        return row
    }

    /// The status row: the dot in the glyph column, the status, and the session's buttons.
    /// `glyphColumn`: the dot sits in the list's glyph column; else at the row's leading edge (the summary).
    private func statusRow(_ sharing: MacScreenHomeSnapshot.Sharing, glyphColumn: Bool = true) -> NSView {
        let status = MacScreenText(sharing.statusText, font: MacScreenType.body, wraps: true)
        status.setAccessibilityIdentifier("macScreen.home.hubStatus")
        status.setContentHuggingPriority(.init(1), for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let dot = MacScreenFill.dot(sharing.statusInk, side: 8)
        var views: [NSView] = [glyphColumn ? glyphCell(dot) : dot, status]
        if let session = sharing.session { views.append(sessionButtons(session)) }
        return MacScreenStack.make(.horizontal, spacing: glyphColumn ? 10 : 6, alignment: .centerY, views)
    }

    /// Revoke This Device and Stop Sharing This Mac, while a device is connected or connecting.
    private func sessionButtons(_ session: MacScreenHubHost.Session) -> NSView {
        let hubHost = devices?.hubHost
        return MacScreenStack.make(.horizontal, spacing: 8, alignment: .centerY, [
            MacScreenButton(L.t("macScreen.indicator.revoke", "Revoke This Device"), compact: true) { hubHost?.revokeViewer() },
            MacScreenButton(L.t("macScreen.indicator.stop", "Stop Sharing This Mac"), role: .destructive, compact: true) {
                hubHost?.stopSession()
            },
        ])
    }

    private func errorRow(_ error: String) -> NSView {
        MacScreenStack.make(.horizontal, spacing: 6, alignment: .firstBaseline, [
            MacScreenGlyph("exclamationmark.circle.fill", font: MacScreenType.caption, ink: \.danger),
            MacScreenText(error, font: MacScreenType.caption, ink: \.danger, wraps: true),
        ])
    }

    private func permissionGlyph(granted: Bool) -> NSView {
        MacScreenGlyph(granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill", font: MacScreenType.body,
                       ink: granted ? \.success : \.attention)
    }

    /// `view` centered in the leading glyph column, so every row's glyph and text line up.
    private func glyphCell(_ view: NSView) -> NSView {
        let cell = NSView()
        cell.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(view)
        NSLayoutConstraint.activate([
            cell.widthAnchor.constraint(equalToConstant: Self.glyphColumn),
            view.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            cell.heightAnchor.constraint(greaterThanOrEqualTo: view.heightAnchor),
        ])
        cell.setContentHuggingPriority(.required, for: .horizontal)
        return cell
    }

    /// `view` with a list row's padding.
    private func padded(_ view: NSView) -> NSView {
        let column = MacScreenStack.make(.vertical, spacing: 0, alignment: .leading, insets: Self.rowInsets)
        MacScreenStack.addFullWidth(view, to: column)
        return column
    }

    /// Adds `view` to `column` as wide as it, less `inset` on the leading edge (an inset hairline).
    private func add(_ view: NSView, to column: NSStackView, inset: CGFloat = 0) {
        guard inset > 0 else {
            MacScreenStack.addFullWidth(view, to: column)
            return
        }
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            view.topAnchor.constraint(equalTo: holder.topAnchor),
            view.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        MacScreenStack.addFullWidth(holder, to: column)
    }

    static func sessionText(_ session: MacScreenHubHost.Session?) -> String {
        text(RdUI.call("homeSharing.sessionText", ["session": rd(session)]), session)
    }

    /// The session as Rust's `homeSharing` ops take it.
    static func rd(_ session: MacScreenHubHost.Session?) -> Any {
        guard let session else { return NSNull() }
        return ["connected": session.connected, "scope": session.scope == .view ? "view" : "full"]
    }

    /// A status dot's ink by Rust's name.
    static func ink(_ name: Any?) -> KeyPath<MacScreenColors, NSColor> {
        switch name as? String {
        case "litGlyph": \.litGlyph
        case "attention": \.attention
        default: \.success
        }
    }

    /// Rust's Text in this person's language: its key localized, `$viewerName` the session's viewer.
    static func text(_ value: Any?, _ session: MacScreenHubHost.Session?) -> String {
        let key = (value as? [String: Any])?["key"] as? String ?? ""
        let words: String = switch key {
        case "macScreen.home.hubReady": L.t("macScreen.home.hubReady", "Ready. Your devices can connect.")
        case "macScreen.home.hubConnecting": L.t("macScreen.home.hubConnecting", "%@ is connecting…")
        case "macScreen.indicator.viewing": L.t("macScreen.indicator.viewing", "%@ is viewing this Mac")
        case "macScreen.indicator.controlling": L.t("macScreen.indicator.controlling", "%@ is controlling this Mac")
        case "macScreen.home.hubNeedsScreenRecording":
            L.t("macScreen.home.hubNeedsScreenRecording", "Allow Screen Recording so your devices can see this Mac.")
        case "macScreen.home.hubViewOnly": L.t("macScreen.home.hubViewOnly", "Ready for View Only. Allow Accessibility for Full Control.")
        case "macScreen.home.connectedViewing": L.t("macScreen.home.connectedViewing", "Connected: %@ · Viewing")
        case "macScreen.home.connectedControlling": L.t("macScreen.home.connectedControlling", "Connected: %@ · Controlling")
        case "macScreen.home.grantBoth": L.t("macScreen.home.grantBoth", "Screen Recording and Accessibility")
        case "macScreen.home.screenRecording": L.t("macScreen.home.screenRecording", "Screen Recording")
        case "macScreen.home.accessibility": L.t("macScreen.home.accessibility", "Accessibility")
        case "macScreen.home.grantDetail": L.t("macScreen.home.grantDetail", "macOS asks once, so your devices can see and control this Mac.")
        case "macScreen.home.grantAccessibilityDetail":
            L.t("macScreen.home.grantAccessibilityDetail", "macOS asks once, so your devices can click and type here.")
        case "macScreen.home.shareThisMacOff": L.t("macScreen.home.shareThisMacOff", "Your devices can’t see or control this Mac.")
        case "macScreen.home.shareThisMacOn": L.t("macScreen.home.shareThisMacOn", "Your devices on this account can connect.")
        default: L.t("macScreen.home.allowToggleShort", "Allow Mac Screen")
        }
        let args = (value as? [String: Any])?["args"] as? [String] ?? []
        guard !args.isEmpty else { return words }
        return String(format: words, arguments: args.map { _ in session?.viewerName ?? "" })
    }
}

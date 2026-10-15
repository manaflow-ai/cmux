public import AppKit
import CmuxNextDesign
import CmuxScreenKit
import CoreImage.CIFilterBuiltins
public import SwiftUI

/// What the home page asks of its owner.
public struct MacScreenHomeActions {
    /// Show a saved Mac in this tab.
    public var open: (UUID) -> Void = { _ in }
    /// Show a saved Mac in a new tab.
    public var openInNewTab: (UUID) -> Void = { _ in }

    public init() {}
}

/// Mac Screen's home page: the Macs this Mac can show, pairing a new one
/// from its link, and Share This Mac with its permissions, link and QR code.
/// Drawn in the tab's theme (`MacScreenColors`, `MacScreenType`).
public struct MacScreenHomeView: View {
    let store: MacScreenStore
    let host: MacScreenShareHost
    let actions: MacScreenHomeActions
    let systemShortcuts: MacScreenSystemShortcuts?
    @State private var linkText = ""
    @State private var addError: MacScreenStore.AddError?
    @State private var renaming: SavedMac?
    @State private var renameText = ""
    @State private var confirmReset = false
    @State private var showLink = false
    @State private var forgetting: SavedMac?
    @State private var copied = false
    @Environment(\.macScreenColors) private var colors

    public init(store: MacScreenStore, host: MacScreenShareHost, actions: MacScreenHomeActions,
                systemShortcuts: MacScreenSystemShortcuts? = nil) {
        self.store = store
        self.host = host
        self.actions = actions
        self.systemShortcuts = systemShortcuts
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                macsSection
                connectSection
                if let systemShortcuts { keyboardSection(systemShortcuts) }
                shareSection
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
        .confirmationDialog(String(format: L.t("macScreen.home.forgetTitle", "Forget %@?"), forgetting?.name ?? ""),
                            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button(L.t("macScreen.home.forget", "Forget This Mac"), role: .destructive) {
                if let mac = forgetting { store.forget(mac.id) }
                forgetting = nil
            }
        } message: {
            Text(L.t("macScreen.home.forgetBody", "To show it again, pair it with its link."))
        }
        // A sheet, not an alert: an alert's text field draws AppKit's focus ring.
        .sheet(item: $renaming) { mac in
            renameSheet(mac)
        }
    }

    private func renameSheet(_ mac: SavedMac) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.t("macScreen.home.renameTitle", "Rename Mac")).font(MacScreenType.subtitle.weight(.semibold))
            ThemedField(text: $renameText, placeholder: L.t("macScreen.home.renameField", "Name"), focusOnAppear: true,
                        identifier: "macScreen.home.renameField", onSubmit: { rename(mac) }, onCancel: { renaming = nil })
            HStack {
                Spacer()
                Button(L.t("macScreen.home.cancel", "Cancel"), role: .cancel) { renaming = nil }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(MacScreenButtonStyle())
                Button(L.t("macScreen.home.rename", "Rename")) { rename(mac) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(MacScreenButtonStyle(role: .primary))
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .font(MacScreenType.body)
        .foregroundStyle(colors.primary)
        .background(colors.popup)
    }

    private func rename(_ mac: SavedMac) {
        store.rename(mac.id, to: renameText)
        renaming = nil
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

    // MARK: Your Macs

    private var macsSection: some View {
        section(L.t("macScreen.home.yourMacs", "Your Macs")) {
            if store.macs.isEmpty {
                Text(L.t("macScreen.home.noMacs", "No Macs yet. Pair one with its link below."))
                    .foregroundStyle(colors.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.macs) { mac in
                        macRow(mac)
                        if mac.id != store.macs.last?.id, colors.borders { colors.separator.frame(height: 1).padding(.leading, 50) }
                    }
                }
            }
        }
    }

    private func macRow(_ mac: SavedMac) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer").font(MacScreenType.glyph).foregroundStyle(colors.secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(mac.name).font(MacScreenType.emphasized)
                Text(lastUsed(mac)).font(MacScreenType.caption).foregroundStyle(colors.secondary)
            }
            Spacer()
            Button(L.t("macScreen.home.connect", "Connect")) { actions.open(mac.id) }
                .buttonStyle(MacScreenButtonStyle(role: .primary))
                .accessibilityIdentifier("macScreen.home.open.\(mac.name)")
            Menu {
                Button(L.t("macScreen.home.openNewTab", "Open in New Tab")) { actions.openInNewTab(mac.id) }
                Button(L.t("macScreen.home.renameMenu", "Rename…")) {
                    renameText = mac.name
                    renaming = mac
                }
                Divider()
                Button(L.t("macScreen.home.forget", "Forget This Mac"), role: .destructive) { forgetting = mac }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .macScreenMenu(colors.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { actions.open(mac.id) }
    }

    private func lastUsed(_ mac: SavedMac) -> String {
        guard let date = mac.lastConnectedAt else { return L.t("macScreen.home.neverConnected", "Not connected yet") }
        return String(format: L.t("macScreen.home.lastConnected", "Last connected %@"),
                      date.formatted(.relative(presentation: .named)))
    }

    // MARK: Connect

    private var connectSection: some View {
        section(L.t("macScreen.home.pairTitle", "Pair a Mac")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L.t("macScreen.home.pairBody", "On the other Mac, open Mac Screen in cmux, turn on Share This Mac and copy its link. Paste it here."))
                    .foregroundStyle(colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    // The theme's field: its box shows focus, never AppKit's ring.
                    ThemedField(text: $linkText, placeholder: L.t("macScreen.home.linkPlaceholder", "cmux-vnc://pair?…"),
                                identifier: "macScreen.home.link", onSubmit: pair)
                        // An error describes the link that was tried; editing the field clears it.
                        .onChange(of: linkText) { addError = nil }
                    Button(L.t("macScreen.home.pair", "Pair and Connect"), action: pair)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(MacScreenButtonStyle(role: .primary))
                        .disabled(linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("macScreen.home.pair")
                }
                if let addError {
                    Label(message(addError), systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(colors.danger).font(MacScreenType.body)
                        .accessibilityIdentifier("macScreen.home.error")
                }
            }
            .padding(14)
        }
    }

    private func pair() {
        switch store.add(link: linkText) {
        case let .success(mac):
            linkText = ""
            addError = nil
            actions.open(mac.id)
        case let .failure(error):
            addError = error
        }
    }

    private func message(_ error: MacScreenStore.AddError) -> String {
        switch error {
        case .notALink: L.t("macScreen.home.error.notALink", "That isn’t a complete Mac Screen link. Copy it again from Share This Mac on the other Mac.")
        case .notAScreenStream: L.t("macScreen.home.error.notAStream", "This link is for a VNC relay, not a screen stream. Share the Mac from cmux or with cmux-vnc-host --capture.")
        case .ownLink: L.t("macScreen.home.error.ownLink", "That is this Mac’s own link. Paste it on the other Mac.")
        case .secretNotSaved: L.t("macScreen.home.error.secretNotSaved", "The Keychain did not save this Mac’s pairing. Unlock your login Keychain and paste the link again.")
        }
    }

    // MARK: Keyboard

    /// Send System Shortcuts to the Remote Mac, and the Accessibility it needs.
    private func keyboardSection(_ shortcuts: MacScreenSystemShortcuts) -> some View {
        section(L.t("macScreen.home.keyboardTitle", "Keyboard")) {
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
                    divider
                    permissionRow(L.t("macScreen.home.accessibility", "Accessibility"),
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

    // MARK: Share This Mac

    private var shareSection: some View {
        section(L.t("macScreen.home.shareTitle", "Share This Mac")) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(get: { host.isEnabled }, set: { host.setEnabled($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("macScreen.home.shareToggle", "Let paired Macs see and control this Mac"))
                        Text(L.t("macScreen.home.shareWarning", "Anyone with this Mac’s link can see its screen and use its keyboard and mouse. Share the link only with your own devices."))
                            .font(MacScreenType.caption).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .tint(colors.focus)
                .accessibilityIdentifier("macScreen.home.shareToggle")
                if host.isEnabled {
                    divider
                    permissionRow(L.t("macScreen.home.screenRecording", "Screen Recording"),
                                  detail: L.t("macScreen.home.screenRecordingDetail", "Lets cmux send this screen. macOS may ask you to quit and reopen cmux."),
                                  granted: host.screenRecordingGranted) { host.openSettings(screenRecording: true) }
                    permissionRow(L.t("macScreen.home.accessibility", "Accessibility"),
                                  detail: L.t("macScreen.home.accessibilityDetail", "Lets the other Mac click and type here. Without it, it can only watch."),
                                  granted: host.accessibilityGranted) { host.openSettings(screenRecording: false) }
                    divider
                    statusRow
                    if let link = host.link { linkRow(link) }
                }
            }
            .padding(14)
        }
    }

    private func permissionRow(_ title: String, detail: String, granted: Bool, action: String? = nil,
                               open: @escaping () -> Void) -> some View {
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

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText).accessibilityIdentifier("macScreen.home.shareStatus")
            Spacer()
            if host.status == .viewing {
                Button(L.t("macScreen.indicator.stop", "Stop Sharing This Mac"), action: host.disconnectViewer)
                    .buttonStyle(MacScreenButtonStyle(role: .destructive, compact: true))
            }
        }
    }

    private var statusText: String {
        switch host.status {
        case .off: L.t("macScreen.home.status.off", "Off")
        case .needsPermission: L.t("macScreen.home.status.permission", "Waiting for Screen Recording permission")
        case .starting: L.t("macScreen.home.status.starting", "Starting…")
        case .waiting: L.t("macScreen.home.status.waiting", "Ready. No Mac is connected.")
        case .viewing: L.t("macScreen.home.status.viewing", "A paired device is viewing and controlling this Mac")
        case .roomLost: L.t("macScreen.home.status.roomLost", "Offline. Reconnecting…")
        case let .sourceFailed(message): String(format: L.t("macScreen.home.status.failed", "Can’t capture the screen: %@"), message)
        case .linkUnavailable: L.t("macScreen.home.status.linkUnavailable", "This Mac’s link can’t be read from the Keychain. Unlock it and try again.")
        }
    }

    private var statusColor: Color {
        switch host.status {
        case .waiting: colors.success
        case .viewing: colors.accent
        case .starting, .roomLost, .needsPermission: colors.attention
        case .sourceFailed, .linkUnavailable: colors.danger
        case .off: colors.tertiary
        }
    }

    private func linkRow(_ link: URL) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L.t("macScreen.home.linkTitle", "This Mac’s link")).font(MacScreenType.emphasized)
                Text(L.t("macScreen.home.linkBody", "Paste it into Mac Screen on your other Mac, or scan the code with the cmux VNC iPhone app."))
                    .font(MacScreenType.caption).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true)
                Text(showLink ? link.absoluteString : String(repeating: "•", count: 28))
                    .font(MacScreenType.code).textSelection(.enabled).lineLimit(3)
                HStack {
                    Button(copied ? L.t("macScreen.home.copied", "Copied") : L.t("macScreen.home.copy", "Copy Link")) {
                        // Marked concealed (nspasteboard.org): clipboard managers do not keep the room secret.
                        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
                        NSPasteboard.general.declareTypes([.string, concealed], owner: nil)
                        NSPasteboard.general.setString(link.absoluteString, forType: .string)
                        NSPasteboard.general.setString("", forType: concealed)
                        copied = true
                    }
                    .accessibilityIdentifier("macScreen.home.copyLink")
                    Button(showLink ? L.t("macScreen.home.hide", "Hide") : L.t("macScreen.home.show", "Show")) { showLink.toggle() }
                    Button(L.t("macScreen.home.reset", "Reset Link…")) { confirmReset = true }
                }
                .buttonStyle(MacScreenButtonStyle(compact: true))
            }
            Spacer()
            if showLink, let image = Self.qrImage(link.absoluteString) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 132, height: 132)
                    .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 6))
            } else {
                Button { showLink = true } label: {
                    Label(L.t("macScreen.home.showCode", "Show Code"), systemImage: "qrcode").frame(width: 132, height: 132)
                }
                .buttonStyle(MacScreenButtonStyle())
            }
        }
        .onChange(of: link) {
            // A new link (Reset Link) starts masked: it is never shown without Show.
            copied = false
            showLink = false
        }
        .confirmationDialog(L.t("macScreen.home.resetTitle", "Reset this Mac’s link?"), isPresented: $confirmReset) {
            Button(L.t("macScreen.home.resetConfirm", "Reset Link"), role: .destructive) { host.resetLink() }
        } message: {
            Text(L.t("macScreen.home.resetBody", "Devices paired with the current link can no longer connect until they pair again."))
        }
    }

    // MARK: Helpers

    private var divider: some View {
        (colors.borders ? colors.separator : colors.hover).frame(height: 1)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(MacScreenType.header).foregroundStyle(colors.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(colors.card, in: RoundedRectangle(cornerRadius: Metrics.panelCornerRadius, style: .continuous))
                .overlay {
                    if colors.borders {
                        RoundedRectangle(cornerRadius: Metrics.panelCornerRadius, style: .continuous).strokeBorder(colors.separator)
                    }
                }
        }
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

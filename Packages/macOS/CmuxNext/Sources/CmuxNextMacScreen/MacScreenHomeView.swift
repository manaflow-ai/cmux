public import AppKit
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

/// `cmux://mac-screen`: the Macs this Mac can show, pairing a new one from
/// its link, and Share This Mac with its permissions, link and QR code.
public struct MacScreenHomeView: View {
    let store: MacScreenStore
    let host: MacScreenShareHost
    let actions: MacScreenHomeActions
    @State private var linkText = ""
    @State private var addError: MacScreenStore.AddError?
    @State private var renaming: SavedMac?
    @State private var renameText = ""
    @State private var confirmReset = false
    @State private var showLink = false
    @State private var forgetting: SavedMac?
    @State private var copied = false

    public init(store: MacScreenStore, host: MacScreenShareHost, actions: MacScreenHomeActions) {
        self.store = store
        self.host = host
        self.actions = actions
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                macsSection
                connectSection
                shareSection
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { host.refreshPermissions() }
        .confirmationDialog(String(format: L.t("macScreen.home.forgetTitle", "Forget %@?"), forgetting?.name ?? ""),
                            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button(L.t("macScreen.home.forget", "Forget This Mac"), role: .destructive) {
                if let mac = forgetting { store.forget(mac.id) }
                forgetting = nil
            }
        } message: {
            Text(L.t("macScreen.home.forgetBody", "To show it again, pair it with its link."))
        }
        .alert(L.t("macScreen.home.renameTitle", "Rename Mac"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L.t("macScreen.home.renameField", "Name"), text: $renameText)
            Button(L.t("macScreen.home.cancel", "Cancel"), role: .cancel) { renaming = nil }
            Button(L.t("macScreen.home.rename", "Rename")) {
                if let mac = renaming { store.rename(mac.id, to: renameText) }
                renaming = nil
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L.t("macScreen.home.title", "Mac Screen"), systemImage: "display")
                .font(.system(size: 26, weight: .bold))
            Text(L.t("macScreen.home.subtitle", "See and control your other Macs from a cmux tab."))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Your Macs

    private var macsSection: some View {
        section(L.t("macScreen.home.yourMacs", "Your Macs")) {
            if store.macs.isEmpty {
                Text(L.t("macScreen.home.noMacs", "No Macs yet. Pair one with its link below."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.macs) { mac in
                        macRow(mac)
                        if mac.id != store.macs.last?.id { Divider().padding(.leading, 50) }
                    }
                }
            }
        }
    }

    private func macRow(_ mac: SavedMac) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer").font(.system(size: 20)).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(mac.name).font(.system(size: 13, weight: .medium))
                Text(lastUsed(mac)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L.t("macScreen.home.connect", "Connect")) { actions.open(mac.id) }
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
            .menuStyle(.borderlessButton).fixedSize()
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
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField(L.t("macScreen.home.linkPlaceholder", "cmux-vnc://pair?…"), text: $linkText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(pair)
                        .accessibilityIdentifier("macScreen.home.link")
                    Button(L.t("macScreen.home.pair", "Pair and Connect"), action: pair)
                        .keyboardShortcut(.defaultAction)
                        .disabled(linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("macScreen.home.pair")
                }
                if let addError {
                    Label(message(addError), systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red).font(.callout)
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
        case .notALink: L.t("macScreen.home.error.notALink", "That is not a Mac Screen link. It starts with cmux-vnc://pair.")
        case .notAScreenStream: L.t("macScreen.home.error.notAStream", "This link is for a VNC relay, not a screen stream. Share the Mac from cmux or with cmux-vnc-host --capture.")
        case .ownLink: L.t("macScreen.home.error.ownLink", "That is this Mac’s own link. Paste it on the other Mac.")
        case .secretNotSaved: L.t("macScreen.home.error.secretNotSaved", "The Keychain did not save this Mac’s pairing. Unlock your login Keychain and paste the link again.")
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
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier("macScreen.home.shareToggle")
                if host.isEnabled {
                    Divider()
                    permissionRow(L.t("macScreen.home.screenRecording", "Screen Recording"),
                                  detail: L.t("macScreen.home.screenRecordingDetail", "Lets cmux send this screen. macOS may ask you to quit and reopen cmux."),
                                  granted: host.screenRecordingGranted) { host.openSettings(screenRecording: true) }
                    permissionRow(L.t("macScreen.home.accessibility", "Accessibility"),
                                  detail: L.t("macScreen.home.accessibilityDetail", "Lets the other Mac click and type here. Without it, it can only watch."),
                                  granted: host.accessibilityGranted) { host.openSettings(screenRecording: false) }
                    Divider()
                    statusRow
                    if let link = host.link { linkRow(link) }
                }
            }
            .padding(14)
        }
    }

    private func permissionRow(_ title: String, detail: String, granted: Bool, open: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Text(L.t("macScreen.home.granted", "Allowed")).font(.caption).foregroundStyle(.secondary)
            } else {
                Button(L.t("macScreen.home.openSettings", "Open System Settings"), action: open).controlSize(.small)
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText).accessibilityIdentifier("macScreen.home.shareStatus")
            Spacer()
            if host.status == .viewing {
                Button(L.t("macScreen.indicator.stop", "Stop Sharing This Mac"), action: host.disconnectViewer).controlSize(.small)
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
        case .waiting: .green
        case .viewing: .blue
        case .starting, .roomLost, .needsPermission: .orange
        case .sourceFailed, .linkUnavailable: .red
        case .off: .gray
        }
    }

    private func linkRow(_ link: URL) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L.t("macScreen.home.linkTitle", "This Mac’s link")).font(.system(size: 13, weight: .medium))
                Text(L.t("macScreen.home.linkBody", "Paste it into Mac Screen on your other Mac, or scan the code with the cmux VNC iPhone app."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(showLink ? link.absoluteString : String(repeating: "•", count: 28))
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(3)
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
                .controlSize(.small)
            }
            Spacer()
            if showLink, let image = Self.qrImage(link.absoluteString) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 132, height: 132)
                    .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 6))
            } else {
                Button { showLink = true } label: {
                    Label(L.t("macScreen.home.showCode", "Show Code"), systemImage: "qrcode").frame(width: 132, height: 132)
                }
                .buttonStyle(.bordered)
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

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
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

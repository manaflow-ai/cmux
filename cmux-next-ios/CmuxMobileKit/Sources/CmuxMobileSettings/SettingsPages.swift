#if os(iOS)
import CmuxMobileAuth
import CmuxMobileDesign
import CmuxMobileModel
import CmuxMobileOnboarding
import SwiftUI
import UIKit
import UserNotifications

private let theme = CmuxMobileTheme.standard

extension View {
    func settingsPage(_ title: LocalizedStringKey) -> some View {
        listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, theme.metrics.settingsRowHeight)
            .scrollContentBackground(.hidden)
            .background(theme.colors.bgGrouped.color.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct AccountPage: View {
    let auth: CmuxMobileAuthModel
    let directory: (any SettingsDeviceDirectory)?
    @State private var methods: SettingsLoad<[SignInMethod]> = .loading
    @State private var confirmsDeletion = false
    @State private var deleting = false
    @State private var deletionError: String?
    /// The sign-in glyph grows with Dynamic Type like the other row icons.
    @ScaledMetric(relativeTo: .body) private var signInGlyph: CGFloat = 18

    var body: some View {
        List {
            if let user = auth.user {
                // The header card only: name and email once, centered, with
                // no row background (Apple Account).
                Section {
                    VStack(spacing: 6) {
                        UserInitials(user.initials, size: 64, background: UserInitials.onGrouped)
                            .padding(.bottom, 6)
                        UnbrokenText(user.name, style: .title2, weight: .semibold, alignment: .center)
                            .foregroundStyle(theme.colors.label)
                            .multilineTextAlignment(.center)
                        if let email = user.email {
                            EmailText(email).font(.subheadline).foregroundStyle(theme.colors.label2)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .accessibilityElement(children: .combine)
                }
            }
            Section {
                switch methods {
                case .loading:
                    CmuxMobileGutterRow {
                        ProgressView()
                    } content: {
                        Text("Loading").foregroundStyle(theme.colors.label2)
                    }
                case .failed(let message):
                    SettingsLoadError(message: message) { Task { await loadMethods() } }
                case .loaded(let list) where list.isEmpty:
                    Text("No sign-in methods are linked.").foregroundStyle(theme.colors.label2).cmuxMobileTextColumn()
                case .loaded(let list):
                    ForEach(list) { method in
                        CmuxMobileGutterRow {
                            SignInMethodGlyph(method, size: min(signInGlyph, 34))
                                .foregroundStyle(theme.colors.label)
                        } content: {
                            HStack {
                                UnbrokenText(method.title)
                                if let detail = method.detail(accountEmail: auth.user?.email) {
                                    Spacer(minLength: 8)
                                    EmailText(detail).font(theme.type.meta).foregroundStyle(theme.colors.label2)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } header: {
                Text("Sign-in methods").cmuxMobileTextColumn()
            }
            Section {
                Button(role: .destructive) {
                    confirmsDeletion = true
                } label: {
                    HStack {
                        Text("Delete Account").foregroundStyle(theme.colors.danger).cmuxMobileTextColumn()
                        if deleting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(deleting)
                .accessibilityIdentifier("settings.deleteAccount")
            } footer: {
                Text("Deletes your cmux account and its data for every cmux app, and removes your Macs and phones from the cmux service. This can't be undone.")
                    .cmuxMobileTextColumn()
            }
        }
        .settingsPage("Account")
        .task(id: auth.user?.id) { await loadMethods() }
        .confirmationDialog("Delete your cmux account?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Your cmux account is used by every cmux app (Mac, iPhone and web). Deleting it signs you out everywhere, removes your Macs and phones from the cmux service and permanently deletes your account. This can't be undone.")
        }
        .alert("Account not deleted", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionError ?? "")
        }
    }

    private func delete() async {
        deleting = true
        defer { deleting = false }
        var purge: (@MainActor () async throws -> Void)?
        if let directory {
            purge = { try await directory.deleteAccountData() }
        }
        do {
            try await auth.deleteAccount(purgeServiceData: purge)
        } catch let error as CmuxMobileAuthModel.AccountDeletionError {
            deletionError = error.message
        } catch {
            deletionError = "Your account couldn't be deleted. Try again."
        }
    }

    private func loadMethods() async {
        methods = .loading
        do {
            methods = .loaded(try await auth.signInMethods())
        } catch is CancellationError {
        } catch {
            methods = .failed("Couldn't load your sign-in methods.")
        }
    }
}

/// A Settings list loaded from the cloud service.
enum SettingsLoad<Value: Sendable>: Sendable {
    case loading
    case loaded(Value)
    case failed(String)
}

/// A failed load with a Retry button.
struct SettingsLoadError: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        CmuxMobileGutterRow {
            SettingsIcon("exclamationmark.triangle").foregroundStyle(theme.colors.label2)
        } content: {
            HStack {
                Text(message).font(theme.type.meta).foregroundStyle(theme.colors.label2)
                Spacer(minLength: 8)
                Button("Retry", action: retry).font(theme.type.rowTitle)
            }
        }
    }
}

struct TeamPage: View {
    let team: Team
    let auth: CmuxMobileAuthModel
    let edit: () -> Void
    let invite: () -> Void
    @State private var members: SettingsLoad<[TeamMember]> = .loading

    var body: some View {
        List {
            Section {
                Button(action: edit) {
                    // Avatars centered on the icon column: every title, header
                    // and footer on the page starts at one x.
                    CmuxMobileGutterRow {
                        SettingsTeamAvatar(team: team, size: 28)
                    } content: {
                        HStack {
                            Text("Color and icon").font(theme.type.rowTitle).foregroundStyle(theme.colors.label)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.colors.label3)
                        }
                    }
                }
            } footer: {
                Text("Color and icon are yours only; teammates choose their own.").cmuxMobileTextColumn()
            }
            Section {
                switch members {
                case .loading:
                    CmuxMobileGutterRow {
                        ProgressView()
                    } content: {
                        Text("Loading members").foregroundStyle(theme.colors.label2)
                    }
                case .failed(let message):
                    SettingsLoadError(message: message) { Task { await loadMembers() } }
                case .loaded(let list):
                    ForEach(list) { member in
                        CmuxMobileGutterRow {
                            UserInitials(member.initials, size: 28)
                        } content: {
                            HStack {
                                Text(member.name).font(theme.type.rowTitle)
                                Spacer()
                                if member.isYou {
                                    Text("You").font(theme.type.meta).foregroundStyle(theme.colors.label2)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } header: {
                Text("Members").cmuxMobileTextColumn()
            }
            // The personal space is just you: nobody to invite.
            if !team.isPersonalSpace {
            Section {
                Button(action: invite) {
                    SettingsLabel("Invite to team", symbol: "person.badge.plus")
                }
            }
            }
        }
        .settingsPage(LocalizedStringKey(team.name))
        .task(id: team.id) { await loadMembers() }
        .refreshable { await loadMembers() }
    }

    private func loadMembers() async {
        if case .loaded = members {} else { members = .loading }
        do {
            members = .loaded(try await auth.teamMembers(teamID: team.id))
        } catch is CancellationError {
        } catch {
            members = .failed("Couldn't load the team's members.")
        }
    }
}

struct TerminalPage: View {
    let settings: SettingsStore

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                Stepper(value: $settings.terminalFontSize, in: CmuxMobilePreferences.terminalFontSizes) {
                    SettingsLabel("Font size", symbol: "textformat.size", value: "\(settings.terminalFontSize) pt")
                }
                Text(verbatim: "~/cmux $ swift build")
                    .font(.system(size: CGFloat(settings.terminalFontSize), design: .monospaced))
                    .foregroundStyle(Color(hex: "#E6E6E6"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.black, in: .rect(cornerRadius: 12, style: .continuous))
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            } footer: {
                Text("Applies to open terminals at once.").cmuxMobileTextColumn()
            }
            Section {
                NavigationLink(value: SettingsRoute.terminalSizing) {
                    SettingsLabel("Terminal Size When Shared", symbol: "rectangle.on.rectangle")
                }
                .accessibilityIdentifier("settings.terminalSizing")
            } footer: {
                Text("Which device's size a terminal takes when this iPhone and the Mac show it at once.")
            }
            Section {
                Toggle(isOn: $settings.wrapCode) { SettingsLabel("Wrap code and diff lines", symbol: "text.word.spacing") }
                Toggle(isOn: $settings.keyClicks) { SettingsLabel("Key clicks", symbol: "keyboard") }
            } header: {
                Text("Code").cmuxMobileTextColumn()
            } footer: {
                Text("Key clicks sound when you tap the keys above the keyboard. They follow the ring/silent switch.").cmuxMobileTextColumn()
            }
        }
        .settingsPage("Terminal")
    }
}

struct ComposerPage: View {
    let settings: SettingsStore

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                Toggle(isOn: $settings.dismissKeyboardAfterSend) {
                    SettingsLabel("Dismiss keyboard after sending", symbol: "keyboard.chevron.compact.down")
                }
                Picker(selection: $settings.followUp) {
                    ForEach(FollowUpBehavior.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingsLabel("Follow-up while running", symbol: "arrow.turn.down.right")
                }
                .pickerStyle(.menu)
            } footer: {
                Text("Queue sends after the current turn. Steer interrupts the agent.").cmuxMobileTextColumn()
            }
        }
        .settingsPage("Composer")
    }
}

/// Settings → Notifications. The permission is real in every build: Chief's
/// replies arrive as local alerts (`ChiefAlerts`) while cmux is running. Only
/// TestFlight builds (push) also get notifications from the Macs.
struct NotificationsPage: View {
    let settings: SettingsStore
    /// The account's Macs, for per-Mac on and off.
    var macs: [MacDevice] = []
    @State private var permission: NotificationPermission?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    private var push: Bool { BuildCapabilities.current.push }

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                Button {
                    if permission == .notDetermined {
                        Task {
                            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
                            if granted, push { UIApplication.shared.registerForRemoteNotifications() }
                            await refresh()
                        }
                    } else if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    SettingsLabel("Allow notifications", symbol: "bell.badge", value: permission?.title)
                }
                .accessibilityIdentifier("settings.notifications.allow")
            } footer: {
                if !push {
                    Text("For Chief's replies, while cmux is open or still running in the background.").cmuxMobileTextColumn()
                }
            }
            if push {
                kindsSection(settings: $settings)
            } else {
                Section {
                    CmuxMobileGutterRow {
                        SettingsIcon("bell.slash").foregroundStyle(theme.colors.label2)
                    } content: {
                        UnbrokenText(String(localized: "Notifications from your Macs need the TestFlight build."))
                            .foregroundStyle(theme.colors.label2)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.notifications.macsUnavailable")
                }
            }
        }
        .settingsPage("Notifications")
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    @ViewBuilder
    private func kindsSection(settings: Bindable<SettingsStore>) -> some View {
        let off = permission == .off
        Group {
            Section {
                Picker(selection: settings.notifyLevel) {
                    ForEach(NotificationLevel.allCases) { level in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(level.title)
                            Text(level.detail).font(.footnote).foregroundStyle(theme.colors.label2)
                        }
                        // No icon: the text still starts at the page's text column.
                        .cmuxMobileTextColumn()
                        .tag(level)
                        .accessibilityIdentifier("settings.notifications.level.\(level.rawValue)")
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Notify me").cmuxMobileTextColumn()
            } footer: {
                if off { Text("Turn on notifications in iOS Settings to choose what you get.").cmuxMobileTextColumn() }
            }
            if !macs.isEmpty {
                Section {
                    ForEach(macs) { mac in
                        Toggle(isOn: Binding(get: { self.settings.notifies(macID: mac.id) },
                                             set: { self.settings.setNotifications(macID: mac.id, on: $0) })) {
                            SettingsLabel("\(mac.name)", symbol: "desktopcomputer")
                        }
                        .accessibilityIdentifier("settings.notifications.mac.\(mac.id)")
                    }
                } header: {
                    Text("Macs").cmuxMobileTextColumn()
                }
            }
            Section {
                Toggle(isOn: settings.notifyPreviews) { SettingsLabel("Show previews", symbol: "text.bubble") }
                    .accessibilityIdentifier("settings.notifications.previews")
            } footer: {
                Text(self.settings.notifyPreviews
                    ? "Notifications show the question, the command or the last lines, so you can answer from the notification."
                    : "The lock screen shows only who needs you and on which Mac.")
                    .cmuxMobileTextColumn()
            }
        }
        .disabled(off)
        .opacity(off ? 0.4 : 1)
    }

    private func refresh() async {
        permission = await NotificationPermission.current()
    }
}

/// Settings → Transport: how this iPhone reaches your Macs. DEBUG and Demo
/// builds add the Relay only developer switch.
struct TransportPage: View {
    let settings: SettingsStore
    /// Whether the service has a relay (nil: not known yet).
    let relayAvailable: Bool?
    #if DEBUG
    @AppStorage(DeveloperOptions.relayOnlyKey) private var relayOnly = false
    @AppStorage(DeveloperOptions.blockUDPKey) private var blockUDP = false
    @AppStorage(DeveloperOptions.browserVideoOnChannelKey) private var browserVideoOnChannel = false
    #endif

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                ForEach(TransportKind.allCases) { kind in
                    Button {
                        guard settings.transport != kind else { return }
                        settings.transport = kind
                        theme.haptics.selection()
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                UnbrokenText(kind.pickerTitle).foregroundStyle(theme.colors.label)
                                UnbrokenText(Self.subtitle(kind), style: .footnote).foregroundStyle(theme.colors.label2)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(theme.colors.label)
                                .opacity(settings.transport == kind ? 1 : 0)
                        }
                        .padding(.vertical, 4)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(settings.transport == kind ? .isSelected : [])
                    .accessibilityIdentifier("settings.transport.\(kind.rawValue)")
                }
            } footer: {
                if relayAvailable == false {
                    Text("Relay unavailable. Connections from outside your network may fail. Switching reconnects to your Macs.")
                } else {
                    Text("Switching reconnects to your Macs.")
                }
            }
            #if DEBUG
            // No icons, as the transport choices above: the page keeps one text column.
            Section {
                Toggle(isOn: $relayOnly) {
                    Text("Relay only")
                }
                // Turning off stays possible when the relay goes away while on.
                .disabled(relayAvailable == false && !relayOnly)
                .accessibilityIdentifier("settings.transport.relayOnly")
                Toggle(isOn: $blockUDP) {
                    Text("Block UDP")
                }
                .disabled(relayAvailable == false && !blockUDP)
                .accessibilityIdentifier("settings.transport.blockUDP")
                Toggle(isOn: $browserVideoOnChannel) {
                    Text("Browser video on channel")
                }
                .accessibilityIdentifier("settings.transport.browserVideoOnChannel")
            } header: {
                Text("Developer")
            } footer: {
                Text(relayAvailable == false
                     ? "Relay unavailable."
                     : "Relay only: always through TURN, as from a distant network. Block UDP (WireGuard; WebRTC ignores it): as on a network that passes only TCP: WireGuard rides TURN over TLS on port 443. Both apply at once. Browser video on channel: streamed browser tabs skip the media lane (RTP on WebRTC or in the WireGuard tunnel). Applies at the next connection.")
            }
            #endif
        }
        .settingsPage("Transport")
    }

    static func subtitle(_ kind: TransportKind) -> String {
        switch kind {
        case .wireguard: String(localized: "Encrypted tunnel to your Mac. Browser tabs stream over WebRTC when that is faster.")
        case .webrtc: String(localized: "Everything over one WebRTC connection, direct when possible.")
        }
    }
}

struct AcknowledgementsPage: View {
    var body: some View {
        List {
            ForEach(Acknowledgement.groups, id: \.id) { group in
                Section {
                    ForEach(group.items, id: \.name) { item in
                        Link(destination: item.url) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(verbatim: item.name).font(theme.type.rowTitle).foregroundStyle(theme.colors.label)
                                    Spacer(minLength: 8)
                                    Text(verbatim: item.license).font(theme.type.meta).foregroundStyle(theme.colors.label2)
                                }
                                Text(item.use).font(theme.type.meta).foregroundStyle(theme.colors.label2)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text(group.title)
                }
            }
        }
        .settingsPage("Acknowledgements")
    }
}

/// Third-party software in the app: the Swift packages CmuxMobileKit links
/// (`CmuxMobileKit/Package.swift`), the Rust crates in the link library
/// (`rust/Cargo.toml`, `cmux-mobile-link-ffi`), and the vendored web renderer
/// (`CmuxMobileMarkdown/Resources/web/THIRD_PARTY.txt`).
struct Acknowledgement: Sendable {
    let name: String
    let license: String
    let use: LocalizedStringResource
    let url: URL

    struct Group: Sendable {
        let id: String
        let title: LocalizedStringResource
        let items: [Acknowledgement]

        init(title: String.LocalizationValue, items: [Acknowledgement]) {
            self.id = "\(items.first?.name ?? "")"
            self.title = LocalizedStringResource(title)
            self.items = items
        }
    }

    private init(_ name: String, _ license: String, _ use: LocalizedStringResource, _ url: String) {
        self.name = name
        self.license = license
        self.use = use
        self.url = URL(string: url)!
    }

    static let groups: [Group] = [
        Group(title: "Terminal", items: [
            Acknowledgement("Ghostty", "MIT", "Terminal emulation and rendering", "https://github.com/ghostty-org/ghostty"),
        ]),
        Group(title: "Connection", items: [
            Acknowledgement("webrtc-rs", "MIT or Apache 2.0", "WebRTC data channels to your Mac", "https://github.com/webrtc-rs/webrtc"),
            Acknowledgement("BoringTun", "BSD 3-Clause", "WireGuard® protocol", "https://github.com/cloudflare/boringtun"),
            Acknowledgement("smoltcp", "0BSD", "TCP/IP inside the WireGuard tunnel", "https://github.com/smoltcp-rs/smoltcp"),
            Acknowledgement("x25519-dalek", "BSD 3-Clause", "Key exchange", "https://github.com/dalek-cryptography/curve25519-dalek"),
            Acknowledgement("rustls", "Apache 2.0, ISC or MIT", "TLS", "https://github.com/rustls/rustls"),
            Acknowledgement("ring", "Apache 2.0 and ISC", "Cryptography", "https://github.com/briansmith/ring"),
            Acknowledgement("Tokio", "MIT", "Asynchronous runtime", "https://github.com/tokio-rs/tokio"),
            Acknowledgement("reqwest", "MIT or Apache 2.0", "HTTP client", "https://github.com/seanmonstar/reqwest"),
            Acknowledgement("tokio-tungstenite", "MIT", "WebSockets", "https://github.com/snapview/tokio-tungstenite"),
            Acknowledgement("ip_network", "BSD 2-Clause", "Tunnel addressing", "https://github.com/JakubOnderka/ip_network"),
            Acknowledgement("Serde", "MIT or Apache 2.0", "Serialization", "https://github.com/serde-rs/serde"),
            Acknowledgement("UniFFI", "MPL 2.0", "Swift bindings for the connection library", "https://github.com/mozilla/uniffi-rs"),
        ]),
        Group(title: "Sign-in", items: [
            Acknowledgement("Stack Auth Swift SDK", "MIT", "Sign-in", "https://github.com/stack-auth/stack-auth"),
            Acknowledgement("swift-crypto", "Apache 2.0", "Cryptography for sign-in", "https://github.com/apple/swift-crypto"),
            Acknowledgement("swift-asn1", "Apache 2.0", "Used by swift-crypto", "https://github.com/apple/swift-asn1"),
        ]),
        Group(title: "Rendering", items: [
            Acknowledgement("marked", "MIT", "Markdown in the Feed", "https://github.com/markedjs/marked"),
            Acknowledgement("Temml", "MIT", "Math", "https://github.com/ronkok/Temml"),
            Acknowledgement("highlight.js", "BSD 3-Clause", "Code highlighting", "https://github.com/highlightjs/highlight.js"),
        ]),
    ]
}
#endif

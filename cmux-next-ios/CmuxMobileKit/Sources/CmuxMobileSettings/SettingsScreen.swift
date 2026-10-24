#if os(iOS)
import CmuxMobileAuth
import CmuxMobileDesign
import CmuxMobileModel
import CmuxMobileRealtime
import SwiftUI
import UIKit
import UserNotifications

private let theme = CmuxMobileTheme.standard

/// Settings tab root (SPEC 9): inset grouped list on `bgGrouped`, leading
/// drawer circle, centered title, sub-pages pushed with the system edge swipe.
public struct SettingsScreen<Leading: ToolbarContent>: View {
    let auth: CmuxMobileAuthModel
    let store: AppStore
    let settings: SettingsStore
    let leading: () -> Leading
    let inviteToTeam: (Team) -> Void
    /// Saves a team's color and icon: the same path as the sidebar's editor
    /// (`PUT /v1/teams/:id/prefs` when live, this iPhone only otherwise).
    let saveAppearance: (TeamAppearance, Team) -> Void
    /// The live service for the device list and account deletion (nil in mock mode).
    let directory: (any SettingsDeviceDirectory)?
    /// The Macs' terminal sizing policies (nil in mock mode).
    let sizing: (any TerminalSizingService)?
    @Binding var path: [SettingsRoute]
    let scrollRequest: String?
    /// Starts a live Chief call (Settings → Chief Calls' Call Chief); nil where calls can't start.
    let callChief: (() -> Void)?
    private let callKeys = OpenAIKeyModel.shared
    private let callPreferences = VoiceCallPreferences.shared
    @State private var confirmsSignOut = false
    @State private var editingTeam: Team?
    /// One device list for the "Devices" count here and the Devices page.
    @State private var deviceList = SettingsDeviceList()
    @State private var notificationPermission: NotificationPermission?
    @Environment(\.scenePhase) private var scenePhase

    public init(auth: CmuxMobileAuthModel, store: AppStore, settings: SettingsStore, path: Binding<[SettingsRoute]>, scrollRequest: String? = nil, directory: (any SettingsDeviceDirectory)? = nil, sizing: (any TerminalSizingService)? = nil, callChief: (() -> Void)? = nil, inviteToTeam: @escaping (Team) -> Void, saveAppearance: @escaping (TeamAppearance, Team) -> Void, @ToolbarContentBuilder leading: @escaping () -> Leading) {
        self.scrollRequest = scrollRequest
        self.callChief = callChief
        self.directory = directory
        self.sizing = sizing
        self.auth = auth
        self.store = store
        self.settings = settings
        _path = path
        self.inviteToTeam = inviteToTeam
        self.saveAppearance = saveAppearance
        self.leading = leading
    }

    public var body: some View {
        @Bindable var settings = settings
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
            List {
                accountSection.id("top")
                if let team = store.activeTeam {
                    Section {
                        NavigationLink(value: SettingsRoute.team) {
                            // The avatar centered on the icon column: the name at the other titles' x.
                            CmuxMobileGutterRow {
                                SettingsTeamAvatar(team: team, size: 28)
                            } content: {
                                UnbrokenText(team.name)
                            }
                        }
                    }
                }
                Section {
                    NavigationLink(value: SettingsRoute.transport) {
                        SettingsLabel("Transport", symbol: "antenna.radiowaves.left.and.right", value: transportValue)
                    }
                    NavigationLink(value: SettingsRoute.devices) {
                        SettingsLabel("Devices", symbol: "laptopcomputer.and.iphone", value: devicesValue)
                    }
                    .accessibilityIdentifier("settings.devices")
                } header: {
                    Text("Connection").cmuxMobileTextColumn()
                }
                Section {
                    NavigationLink(value: SettingsRoute.chiefCalls) {
                        SettingsLabel("Chief Calls", symbol: "phone",
                                      value: callKeys.hasKey ? callPreferences.model.title : String(localized: "Not set up"))
                    }
                    .accessibilityIdentifier("settings.chiefCalls.row")
                    NavigationLink(value: SettingsRoute.terminal) {
                        SettingsLabel("Terminal", symbol: "apple.terminal", value: "\(settings.terminalFontSize) pt")
                    }
                    NavigationLink(value: SettingsRoute.composer) {
                        SettingsLabel("Composer", symbol: "keyboard", value: settings.followUp.title)
                    }
                }
                Section {
                    AppearanceTiles(selection: $settings.appearance)
                        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                    Toggle(isOn: $settings.hapticsEnabled) {
                        SettingsLabel("Haptic feedback", symbol: "iphone.radiowaves.left.and.right")
                    }
                } header: {
                    Text("Appearance").cmuxMobileTextColumn()
                }
                .id("appearance")
                Section {
                    NavigationLink(value: SettingsRoute.notifications) {
                        SettingsLabel("Notifications", symbol: "bell",
                                      value: notificationPermission?.rootValue(push: BuildCapabilities.current.push))
                    }
                    Toggle(isOn: $settings.requireFaceID) {
                        SettingsLabel("Require Face ID", symbol: "faceid")
                    }
                } header: {
                    Text("Privacy & notifications").cmuxMobileTextColumn()
                } footer: {
                    Text("Require Face ID or passcode to open cmux on this device.").cmuxMobileTextColumn()
                }
                #if DEBUG
                DeveloperSection(auth: auth)
                #endif
                Section {
                    LinkRow("Help", symbol: "questionmark.circle", url: "https://cmux.com/docs")
                    LinkRow("Report a problem", symbol: "flag", url: "https://github.com/manaflow-ai/cmux/issues")
                    LinkRow("Terms of Use", symbol: "doc.text", url: "https://cmux.com/terms")
                    LinkRow("Privacy Policy", symbol: "hand.raised", url: "https://cmux.com/privacy")
                    NavigationLink(value: SettingsRoute.acknowledgements) {
                        SettingsLabel("Acknowledgements", symbol: "info.circle")
                    }
                } header: {
                    Text("About").cmuxMobileTextColumn()
                }
                Section {
                    Button(role: .destructive) {
                        confirmsSignOut = true
                    } label: {
                        CmuxMobileGutterRow {
                            SettingsIcon("rectangle.portrait.and.arrow.right").accessibilityHidden(true)
                        } content: {
                            Text("Sign out").font(theme.type.rowTitle)
                        }
                        .foregroundStyle(theme.colors.danger)
                    }
                    .accessibilityIdentifier("settings.logout")
                    .confirmationDialog("Sign out of cmux?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
                        Button("Sign out", role: .destructive) { Task { await auth.signOut() } }
                    }
                } footer: {
                    VersionFooter().id("bottom")
                }
            }
            .onChange(of: scrollRequest) { _, target in
                guard let target else { return }
                withAnimation(theme.motion.gentle.animation) { proxy.scrollTo(target, anchor: target == "bottom" ? .bottom : .top) }
            }
            .listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, theme.metrics.settingsRowHeight)
            .scrollContentBackground(.hidden)
            .background(theme.colors.bgGrouped.color.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { leading() }
            .navigationDestination(for: SettingsRoute.self) { route in
                destination(route)
            }
            .sheet(item: $editingTeam) { team in
                TeamAppearanceEditor(team: team) { saveAppearance($0, team) }
            }
            // The count follows the account's Macs as discovery finds them.
            .task(id: store.accountMacCount) { await deviceList.load(directory) }
            .onAppear { Task { notificationPermission = await NotificationPermission.current() } }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { notificationPermission = await NotificationPermission.current() }
            }
            }
        }
        .cmuxMobileNeutralControlTint()
    }

    /// The Devices page's Mac rows, counted; no value until they load.
    private var devicesValue: String? {
        SettingsDeviceRows.rootValue(service: deviceList.devices, hasService: directory != nil,
                                     liveMacs: store.teams.flatMap(\.macs))
    }

    private var transportValue: String {
        #if DEBUG
        return settings.transport.settingsValue(blockUDP: DeveloperOptions.blockUDP, relayOnly: DeveloperOptions.relayOnly)
        #else
        return settings.transport.title
        #endif
    }

    @ViewBuilder private var accountSection: some View {
        if let user = auth.user {
            Section {
                NavigationLink(value: SettingsRoute.account) {
                    HStack(spacing: 14) {
                        UserInitials(user.initials, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            UnbrokenText(user.name, weight: .semibold)
                            if let email = user.email {
                                EmailText(email).font(theme.type.meta).foregroundStyle(theme.colors.label2)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder private func destination(_ route: SettingsRoute) -> some View {
        switch route {
        case .account: AccountPage(auth: auth, directory: directory)
        case .team:
            if let team = store.activeTeam {
                TeamPage(team: team, auth: auth, edit: { editingTeam = team }, invite: { inviteToTeam(team) })
            }
        case .transport: TransportPage(settings: settings, relayAvailable: directory?.relayAvailable)
        case .devices: DevicesPage(store: store, directory: directory, list: deviceList)
        case .terminal: TerminalPage(settings: settings)
        case .terminalSizing: TerminalSizingMacsPage(store: store)
        case .terminalSizingMac(let macID): TerminalSizingMacPage(macID: macID, store: store, service: sizing)
        case .composer: ComposerPage(settings: settings)
        case .notifications: NotificationsPage(settings: settings, macs: store.notificationMacs)
        case .acknowledgements: AcknowledgementsPage()
        case .chiefCalls: ChiefCallsPage(keys: callKeys, preferences: callPreferences, callChief: callChief)
        }
    }
}

/// Pushed settings pages.
public enum SettingsRoute: Hashable, Sendable {
    case account, team, transport, devices, terminal, composer, notifications, acknowledgements
    /// Chief Calls: the OpenAI API key, model and voice for live calls with Chief.
    case chiefCalls
    /// Terminal → Terminal Size When Shared, and one Mac's page under it.
    case terminalSizing
    case terminalSizingMac(String)

    /// The route named by its case name (DEBUG launch arguments). The old
    /// name "pairedMacs" opens Devices.
    public init?(name: String) {
        if name == "pairedMacs" {
            self = .devices
            return
        }
        let all: [SettingsRoute] = [.account, .team, .transport, .devices, .terminal, .terminalSizing, .composer, .notifications,
                                    .acknowledgements, .chiefCalls]
        guard let route = all.first(where: { "\($0)" == name }) else { return nil }
        self = route
    }
}

/// A settings row icon: 17 pt line symbol in a 22 pt frame, both growing with
/// Dynamic Type up to twice their size.
struct SettingsIcon: View {
    let symbol: String
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 17
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ symbol: String) {
        self.symbol = symbol
    }

    var body: some View {
        // The grouped lists' icon column, the one header and footer text start after.
        Image(systemName: symbol)
            .font(.system(size: min(size, 34)))
            .frame(width: CmuxMobileListColumn.grouped(typeSize).mark)
    }
}

/// A settings row label: icon, title, trailing value. At accessibility text
/// sizes the value goes under the title, as in iOS Settings, so the title
/// never breaks mid-word.
struct SettingsLabel: View {
    let title: String
    let symbol: String
    let value: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ title: LocalizedStringResource, symbol: String, value: String? = nil) {
        self.title = String(localized: title)
        self.symbol = symbol
        self.value = value
    }

    var body: some View {
        HStack(spacing: CmuxMobileListColumn.groupedGap) {
            SettingsIcon(symbol).foregroundStyle(theme.colors.label)
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    UnbrokenText(title).foregroundStyle(theme.colors.label)
                    if let value {
                        Text(value).font(theme.type.rowTitle).foregroundStyle(theme.colors.label2)
                    }
                }
            } else {
                Text(verbatim: title).font(theme.type.rowTitle).foregroundStyle(theme.colors.label)
                if let value {
                    Spacer(minLength: 8)
                    Text(value).font(theme.type.rowTitle).foregroundStyle(theme.colors.label2).lineLimit(1)
                }
            }
        }
    }
}

/// An email address on one line: shrinks, then truncates in the middle;
/// never hyphenated.
struct EmailText: View {
    let email: String

    init(_ email: String) {
        self.email = email
    }

    var body: some View {
        Text(verbatim: email)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .truncationMode(.middle)
    }
}

/// A team avatar that grows with Dynamic Type (up to twice its size).
struct SettingsTeamAvatar: View {
    let team: Team
    let size: CGFloat
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        TeamAvatar(
            name: team.name, colorHex: team.appearance.colorHex, emoji: team.appearance.emoji,
            size: size * min(scale, 2), transparent: team.appearance.isTransparent
        )
    }
}

extension NotificationPermission {
    /// The system's current answer (nil outside an app bundle).
    static func current() async -> NotificationPermission? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .on
        case .denied: return .off
        case .notDetermined: return .notDetermined
        @unknown default: return nil
        }
    }
}

struct LinkRow: View {
    let title: LocalizedStringResource
    let symbol: String
    let url: String
    @Environment(\.openURL) private var openURL

    init(_ title: LocalizedStringResource, symbol: String, url: String) {
        self.title = title
        self.symbol = symbol
        self.url = url
    }

    var body: some View {
        Button {
            if let url = URL(string: url) { openURL(url) }
        } label: {
            HStack {
                SettingsLabel(title, symbol: symbol)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.colors.label3)
            }
        }
    }
}

/// Initials in a circle on `surfaceRaised` (Claude's "AA").
struct UserInitials: View {
    let initials: String
    let size: CGFloat
    let background: CmuxMobileColorToken
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    /// Raised gray inside a row; white on the light grouped background
    /// (Account's header, which has no row).
    static let onGrouped = CmuxMobileColorToken(dark: CmuxMobileRGBA(hex: "#2C2C2E"), light: CmuxMobileRGBA(hex: "#FFFFFF"))

    init(_ initials: String, size: CGFloat, background: CmuxMobileColorToken = theme.colors.surfaceRaised) {
        self.initials = initials
        self.size = size
        self.background = background
    }

    var body: some View {
        let size = size * min(scale, 2)
        Text(initials)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(theme.colors.label)
            .frame(width: size, height: size)
            .background(background, in: .circle)
            .accessibilityHidden(true)
    }
}

/// Light / Dark / System tiles (96 x 64 previews, selected 2 pt `label` stroke).
struct AppearanceTiles: View {
    @Binding var selection: AppearanceMode

    var body: some View {
        HStack(spacing: 12) {
            ForEach(AppearanceMode.allCases) { mode in
                let selected = mode == selection
                Button {
                    selection = mode
                    theme.haptics.selection()
                } label: {
                    VStack(spacing: 8) {
                        AppearancePreview(mode: mode)
                            .frame(height: 64)
                            .clipShape(.rect(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(selected ? theme.colors.label.color : theme.colors.separator.color, lineWidth: selected ? 2 : 0.5)
                            }
                            .animation(theme.motion.snap.animation, value: selected)
                        Text(mode.title)
                            .font(theme.type.meta.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? theme.colors.label : theme.colors.label2)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

private struct AppearancePreview: View {
    let mode: AppearanceMode

    var body: some View {
        ZStack {
            switch mode {
            case .light: page(dark: false)
            case .dark: page(dark: true)
            case .system:
                page(dark: false)
                page(dark: true).mask { DiagonalHalf() }
            }
        }
    }

    private func page(dark: Bool) -> some View {
        let bg = dark ? Color.black : Color.white
        let ink = dark ? Color.white : Color.black
        return ZStack(alignment: .topLeading) {
            bg
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(ink.opacity(0.55)).frame(width: 34, height: 4)
                Capsule().fill(ink.opacity(0.3)).frame(width: 24, height: 4)
            }
            .padding(10)
            Circle().fill(ink).frame(width: 12, height: 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(9)
        }
    }
}

private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

#if DEBUG
/// Settings → Developer (DEBUG and Demo builds): demo toggles read at launch,
/// so a phone demo needs no launch arguments. Relay only lives on the
/// Transport page.
private struct DeveloperSection: View {
    let auth: CmuxMobileAuthModel
    @AppStorage(DeveloperOptions.mockDataKey) private var mockData = false
    @AppStorage(DeveloperOptions.launchDemoKey) private var launchDemo = ""
    @AppStorage(DeveloperOptions.slowFaceIDKey) private var slowFaceID = false
    @State private var launchedWithMock = DeveloperOptions.mockData

    var body: some View {
        let mock = DeveloperOptions.mockSwitch(stored: mockData)
        Section {
            Toggle(isOn: Binding(get: { mock.on }, set: { mockData = $0 })) {
                SettingsLabel("Mock (layout only)", symbol: "theatermasks")
            }
            .disabled(mock.forced)
            .accessibilityIdentifier("settings.developer.mock")
            // Mock approvals wait 2 s, so "Waiting for Face ID…" can be seen.
            Toggle(isOn: $slowFaceID) {
                SettingsLabel("Slow mock Face ID", symbol: "faceid")
            }
            .disabled(!mock.on)
            Picker(selection: $launchDemo) {
                Text("None").tag("")
                ForEach(DeveloperOptions.demos, id: \.id) { demo in
                    Text(verbatim: demo.title).tag(demo.id)
                }
            } label: {
                SettingsLabel("Demo at next launch", symbol: "play.rectangle")
            }
            .pickerStyle(.menu)
            HStack {
                SettingsLabel("Service", symbol: "server.rack")
                Spacer()
                Text(verbatim: auth.apiBaseURL?.host() ?? (auth.isMock ? "Mock" : "None"))
                    .foregroundStyle(theme.colors.label3)
                    .lineLimit(1)
            }
            if mockData != launchedWithMock || !launchDemo.isEmpty {
                Button(role: .destructive) {
                    exit(0)
                } label: {
                    SettingsLabel("Quit to apply", symbol: "arrow.clockwise")
                }
            }
        } header: {
            Text("Developer").cmuxMobileTextColumn()
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(mock.forced ? "Set by the launch environment." : "Sample user, teams and Macs for checking layout. Applies at next launch.")
                Text("Dev test account: enter 42 as the email.")
            }
            .cmuxMobileTextColumn()
        }
    }
}
#endif

/// "Version 1.0 (123) · tag", centered, text only.
struct VersionFooter: View {
    var body: some View {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String ?? "1"
        let tag = (info["CmuxMobileTag"] as? String).flatMap { $0.isEmpty ? nil : $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        Text(verbatim: "Version \(version) (\(build))" + (tag.map { " · \($0)" } ?? ""))
            .font(theme.type.legal)
            .foregroundStyle(theme.colors.label3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .accessibilityElement(children: .combine)
    }
}
#endif

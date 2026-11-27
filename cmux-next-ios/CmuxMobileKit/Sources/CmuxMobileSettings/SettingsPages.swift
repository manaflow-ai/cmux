#if os(iOS)
import CmuxMobileAuth
import CmuxMobileDesign
import CmuxMobileModel
import CmuxMobileOnboarding
import CmuxMobileRealtime
import CmuxSpinner
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
    /// The account `methods` was loaded for.
    @State private var methodsUserID: String?
    @State private var confirmsDeletion = false
    /// Apple's subscription page while the App Store warning is up.
    @State private var renewingSubscription: URL?
    /// Delete Account was tapped and the pre-delete check is in flight; its
    /// task runs from `.task(id:)`, so leaving the page cancels it.
    @State private var checkingDeletion = false
    @State private var deleting = false
    @State private var deletionError: String?
    /// A failed sign-in methods read is read again on its own (no Retry).
    @State private var methodsRetry = AutoRetry()
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
                        CmuxSpinner()
                    } content: {
                        Text("Loading").foregroundStyle(theme.colors.label2)
                    }
                case .failed(let message):
                    SettingsLoadError(message: message, autoRetry: methodsRetry, loading: "Loading")
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
                Text("Sign-in methods")
            }
            Section {
                Button(role: .destructive) {
                    // Set here, before the next render, so a second tap
                    // cannot start a second check.
                    checkingDeletion = true
                } label: {
                    HStack {
                        Text("Delete Account").foregroundStyle(theme.colors.danger).cmuxMobileTextColumn()
                        if deleting || checkingDeletion {
                            Spacer()
                            CmuxSpinner()
                        }
                    }
                }
                .disabled(deleting || checkingDeletion)
                .accessibilityIdentifier("settings.deleteAccount")
            } footer: {
                Text("Permanently deletes your account and data across all cmux apps.")
            }
        }
        .settingsPage("Account")
        .task(id: auth.user?.id) { await loadMethods() }
        .autoRetry(methodsRetry, failing: methods.failed) { await loadMethods(retrying: true) }
        .task(id: checkingDeletion) { if checkingDeletion { await askBeforeDeleting() } }
        // An alert, not a confirmation dialog: on iOS 26 a confirmation
        // dialog opens as a popover with no Cancel button, closed only by a
        // tap outside it. Account deletion (Guideline 5.1.1(v)) shows Cancel
        // beside Delete Account on every iPhone and iPad.
        .alert("Delete your cmux account?", isPresented: $confirmsDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Account", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Your cmux account is used by every cmux app (Mac, iPhone and web). Deleting it signs you out everywhere, removes your Macs and phones from the cmux service and permanently deletes your account. This can't be undone.")
        }
        // Deleting the account does not cancel an App Store subscription
        // (Guideline 5.1.1(v)): Apple keeps charging until it is cancelled in
        // the App Store. This alert stands in for the confirmation above, so
        // its Delete Account deletes.
        .alert(
            Text(String(localized: "mobile.account.deleteAppStore.title", defaultValue: "Your subscription keeps renewing", bundle: .module)),
            isPresented: Binding(get: { renewingSubscription != nil }, set: { if !$0 { renewingSubscription = nil } }),
            presenting: renewingSubscription
        ) { manageURL in
            Button(String(localized: "mobile.account.deleteAppStore.manage", defaultValue: "Manage Subscription", bundle: .module)) {
                Task { await openAppStoreSubscriptionManagement(fallback: manageURL) }
            }
            Button("Delete Account", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(String(localized: "mobile.account.deleteAppStore.message", defaultValue: "Deleting your cmux account doesn't cancel your App Store subscription: cancel it in the App Store. Deletion signs you out everywhere and is permanent.", bundle: .module))
        }
        .alert("Account not deleted", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionError ?? "")
        }
    }

    /// Delete Account: asks the cmux service whether an App Store
    /// subscription will keep renewing, then shows the App Store warning or
    /// the plain confirmation (``AccountDeletionPrompt``).
    private func askBeforeDeleting() async {
        let check = await auth.accountDeletionCheck()
        guard !Task.isCancelled else { return }
        checkingDeletion = false
        switch AccountDeletionPrompt(check: check) {
        case .appStoreSubscriptionWarning(let manageURL): renewingSubscription = manageURL
        case .confirmation: confirmsDeletion = true
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
            // retry-prompt-ok: deleting the account is permanent; asking again is the person's choice
            deletionError = "Your account couldn't be deleted. Try again."
        }
    }

    private func loadMethods(retrying: Bool = false) async {
        // The page reloads each time it is shown again (a tab switch back to Settings): it keeps
        // the rows it has instead of swapping them for "Loading" and back, as the Team page does.
        // Only a first load or another account shows "Loading". A retry keeps the failure until
        // it answers, so the row does not blink.
        let userID = auth.user?.id
        if case .loaded = methods, methodsUserID == userID {} else if !(retrying && methodsUserID == userID) { methods = .loading }
        methodsUserID = userID
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

    /// The load failed (its page retries on its own).
    var failed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// A failed load, read again on its own (`autoRetry`, no Retry button): the loading row stays
/// through a short failure; past the quiet bound the row says why, with the quiet line.
struct SettingsLoadError: View {
    let message: String
    let autoRetry: AutoRetry
    let loading: LocalizedStringKey

    var body: some View {
        if autoRetry.isQuietLineShown {
            CmuxMobileGutterRow {
                SettingsIcon("exclamationmark.triangle").foregroundStyle(theme.colors.label2)
            } content: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(message).font(theme.type.meta).foregroundStyle(theme.colors.label2)
                    AutoRetryQuietLine(autoRetry)
                }
            }
        } else {
            CmuxMobileGutterRow {
                CmuxSpinner()
            } content: {
                Text(loading).foregroundStyle(theme.colors.label2)
            }
        }
    }
}

struct TeamPage: View {
    let team: Team
    let auth: CmuxMobileAuthModel
    let edit: () -> Void
    let invite: () -> Void
    private let cache: LastKnownList?
    @State private var members: SettingsLoad<[TeamMember]>
    @State private var memberRequest = 0
    /// A failed members read is read again on its own (no Retry).
    @State private var membersRetry = AutoRetry()

    init(team: Team, auth: CmuxMobileAuthModel, cache: LastKnownList?, edit: @escaping () -> Void, invite: @escaping () -> Void) {
        self.team = team
        self.auth = auth
        self.cache = cache
        self.edit = edit
        self.invite = invite
        _members = State(initialValue: cache?.read([TeamMember].self).map(SettingsLoad.loaded) ?? .loading)
    }

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
                Text("Only you see these changes.")
            }
            Section {
                switch members {
                case .loading:
                    CmuxMobileGutterRow {
                        // placeholder-ok: No member list has ever been received for this account and team.
                        CmuxSpinner()
                    } content: {
                        // placeholder-ok: First load of this team's member list.
                        Text("Loading members").foregroundStyle(theme.colors.label2)
                    }
                case .failed(let message):
                    SettingsLoadError(message: message, autoRetry: membersRetry, loading: "Loading members")
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
                Text("Members")
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
        .autoRetry(membersRetry, failing: members.failed) { await loadMembers(retrying: true) }
    }

    private func loadMembers(retrying: Bool = false) async {
        memberRequest += 1
        let request = memberRequest
        // A retry keeps the failure until it answers, so the row does not blink.
        if case .loaded = members {} else if !retrying { members = .loading }
        let userID = auth.user?.id
        do {
            let list = try await auth.teamMembers(teamID: team.id)
            guard !Task.isCancelled, request == memberRequest, userID == auth.user?.id else { return }
            members = .loaded(list)
            cache?.save(list)
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, request == memberRequest, userID == auth.user?.id else { return }
            if case .loaded = members { return }
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
            }
            Section {
                NavigationLink(value: SettingsRoute.terminalSizing) {
                    SettingsLabel("Terminal Size When Shared", symbol: "rectangle.on.rectangle")
                }
                .accessibilityIdentifier("settings.terminalSizing")
            } footer: {
                Text("Choose which device controls the shared terminal's size.")
            }
            Section {
                Toggle(isOn: $settings.terminalFitToPhone) { SettingsLabel("Fit to Phone", symbol: "iphone") }
                    .accessibilityIdentifier("settings.terminalFitToPhone")
                Toggle(isOn: $settings.terminalPhoneProjection) { SettingsLabel("Re-wrap on Phone", symbol: "text.alignleft") }
                    .accessibilityIdentifier("settings.terminalPhoneProjection")
            } footer: {
                Text("By default, terminals keep the Mac's columns. Re-wrap on Phone adapts text to the phone without resizing the Mac. Fit to Phone resizes the Mac instead. Applies to terminals opened next.")
            }
            Section {
                Toggle(isOn: $settings.predictiveEcho) { SettingsLabel("Predictive echo", symbol: "bolt.horizontal") }
                    .accessibilityIdentifier("settings.predictiveEcho")
            } footer: {
                Text("On a slow connection, what you type shows at once, underlined until the remote confirms it.")
            }
            Section {
                Toggle(isOn: $settings.predictiveEchoFullScreen) {
                    SettingsLabel("Predictive Echo in Full-Screen Apps", symbol: "bolt.horizontal.circle")
                }
                .accessibilityIdentifier("settings.predictiveEchoFullScreen")
                .disabled(!settings.predictiveEcho)
            } footer: {
                Text("Also predicts typing into full-screen apps such as Claude Code and Codex. A key shows only after the app printed the two before it where they were typed.")
            }
            Section {
                Toggle(isOn: $settings.terminalJumpToBottom) {
                    SettingsLabel("Jump to Bottom Button", symbol: "arrow.down.to.line")
                }
                .accessibilityIdentifier("settings.terminalJumpToBottom")
            } footer: {
                Text("Shows a Jump to bottom button above the composer when you scroll up. Full-screen apps such as vim never show it.")
            }
            Section {
                Toggle(isOn: $settings.terminalComposerAutocorrect) {
                    SettingsLabel("Composer Autocorrect", symbol: "textformat.abc")
                }
                .accessibilityIdentifier("settings.terminalComposerAutocorrect")
            } footer: {
                Text("Corrects and predicts words in the terminal composer, for talking to an agent in prose. Also in the composer's + menu.")
            }
            Section {
                Toggle(isOn: $settings.terminalChatToggle) {
                    SettingsLabel("Terminal and Chat Toggle", symbol: "arrow.left.arrow.right")
                }
                .accessibilityIdentifier("settings.terminalChatToggle")
            } footer: {
                Text("Adds Show Chat and Show Terminal to a Claude Code or Codex tab's menu when both views can open.")
            }
            Section {
                Toggle(isOn: $settings.terminalPlainScroll) {
                    SettingsLabel("Plain Scroll in Full-Screen Apps", symbol: "scroll")
                }
                .accessibilityIdentifier("settings.terminalPlainScroll")
            } footer: {
                Text("Scrolling up in a full-screen app such as Claude Code moves through the rows this phone already has, like any page, instead of asking the app to scroll.")
            }
            Section {
                Toggle(isOn: $settings.terminalZoomFullScreenApps) {
                    SettingsLabel("Zoom Full-Screen Apps", symbol: "plus.magnifyingglass")
                }
                .accessibilityIdentifier("settings.terminalZoomFullScreenApps")
            } footer: {
                Text("Shows vim, htop or Codex at the Mac's size: pinch to zoom, drag to pan, and the Mac pane keeps its size. Typing into one fits it to the phone, which remembers that program. Applies to terminals opened next.")
            }
            Section {
                Toggle(isOn: $settings.terminalHistoryFind) {
                    SettingsLabel("Find in Whole History", symbol: "doc.text.magnifyingglass")
                }
                .accessibilityIdentifier("settings.terminalHistoryFind")
            } footer: {
                Text("Find searches the terminal's whole history on the Mac, not only the lines on this phone.")
            }
            Section {
                Toggle(isOn: $settings.wrapCode) { SettingsLabel("Wrap code and diff lines", symbol: "text.word.spacing") }
                Toggle(isOn: $settings.keyClicks) { SettingsLabel("Key clicks", symbol: "keyboard") }
            } header: {
                Text("Code")
            } footer: {
                Text("Key clicks follow the silent switch.")
            }
        }
        .settingsPage("Terminal")
    }
}

struct ComposerPage: View {
    let settings: SettingsStore
    let voice: VoiceCallPreferences
    /// `ComposerFooterFactsMode` (CmuxMobileAgentChat), stored by its raw value.
    @AppStorage(CmuxMobilePreferences.Key.composerFooterFacts) private var footerFacts = "off"

    var body: some View {
        @Bindable var settings = settings
        @Bindable var voice = voice
        List {
            Section {
                Toggle(isOn: $settings.dismissKeyboardAfterSend) {
                    SettingsLabel("Dismiss keyboard after sending", symbol: "keyboard.chevron.compact.down")
                }
                Toggle(isOn: $settings.swipeDownCollapsesComposer) {
                    SettingsLabel("Swipe down to collapse", symbol: "chevron.compact.down")
                }
                // RFD 0130: the session's facts in the composer, off by default ("default MAY need a call").
                Picker(selection: $footerFacts) {
                    Text("Off").tag("off")
                    Text("Counters").tag("pulse")
                    Text("Card Only").tag("door")
                } label: {
                    SettingsLabel("Session Facts", symbol: "info.circle")
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.composer.sessionFacts")
                Picker(selection: $settings.followUp) {
                    ForEach(FollowUpBehavior.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingsLabel("Follow-up while running", symbol: "arrow.turn.down.right")
                }
                .pickerStyle(.menu)
            } footer: {
                // The Mac's Toggle Prompt Queueing: Send steers either way, as the Mac's Return does.
                Text("Send steers the running turn. With Queue, a long press on Send can queue a message for after the turn; with Steer, that steers too.")
            }
            // Off by default (Leo, 2026-11-22: "im hiding this by default"): voice mode
            // runs on the user's own OpenAI key, so it shows only for people who turn it on.
            Section {
                Picker(selection: $voice.composerVoice) {
                    ForEach(ComposerVoicePlacement.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingsLabel("Voice Button", symbol: "waveform")
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.composer.voiceButton")
                if voice.composerVoice != .off {
                    NavigationLink(value: SettingsRoute.chiefCalls) {
                        SettingsLabel("OpenAI API Key", symbol: "key")
                    }
                    .accessibilityIdentifier("settings.composer.voiceKey")
                }
            } header: {
                Text("Voice Mode")
            } footer: {
                Text("Adds a button that starts voice mode: the agent’s replies are read aloud and what you say is sent. It uses your own OpenAI API key. To dictate into the field, use the keyboard’s microphone.")
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
    let macs: [MacDevice]
    @State private var permission: NotificationPermission?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    /// `permission` is the answer the Settings root already read, so the page opens with the
    /// "Allow notifications" value, its footer and the dimmed sections drawn instead of popping
    /// in a moment later. `refresh()` still reads the system again when the page appears.
    init(settings: SettingsStore, macs: [MacDevice] = [], permission: NotificationPermission? = nil) {
        self.settings = settings
        self.macs = macs
        _permission = State(initialValue: permission)
    }

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
                    Text("Chief alerts require cmux to stay running.")
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
                Text("Notify me")
            } footer: {
                if off { Text("Enable notifications in iOS Settings.") }
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
                    Text("Macs")
                }
            }
            Section {
                Toggle(isOn: settings.notifyPreviews) { SettingsLabel("Show previews", symbol: "text.bubble") }
                    .accessibilityIdentifier("settings.notifications.previews")
            } footer: {
                Text(self.settings.notifyPreviews
                    ? "Notifications include the question or recent output."
                    : "The lock screen shows only who needs you and the Mac.")
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
    let store: AppStore
    /// Whether the service has a relay (nil: not known yet).
    let relayAvailable: Bool?
    #if DEBUG
    @AppStorage(DeveloperOptions.relayOnlyKey) private var relayOnly = false
    @AppStorage(DeveloperOptions.blockUDPKey) private var blockUDP = false
    @AppStorage(DeveloperOptions.forceRelayKey) private var forceRelay = false
    @AppStorage(DeveloperOptions.proxyOnlyKey) private var proxyOnly = false
    @AppStorage(DeveloperOptions.dropWireGuardKey) private var dropWireGuard = false
    @AppStorage(DeveloperOptions.browserVideoOnChannelKey) private var browserVideoOnChannel = false
    @AppStorage(DeveloperOptions.paintLatencyOverlayKey) private var paintLatencyOverlay = false
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
                            UnbrokenText(kind.pickerTitle).foregroundStyle(theme.colors.label)
                            Spacer(minLength: 8)
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(theme.colors.label)
                                .opacity(settings.transport == kind ? 1 : 0)
                        }
                        .padding(.vertical, 4)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.cmuxPressFill)
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
            Section {
                Picker(selection: $settings.ultra) {
                    ForEach(UltraConnection.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Ultra mode")
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.transport.ultra")
            } footer: {
                Text("Auto sends no extra data while the network is clean, and repair data within a round trip of the first lost packet, so a dropped packet costs milliseconds instead of seconds. On cellular, Auto keeps the repair data within the data it protects; Always sends it on every network, at about 2 to 3 times the data. Applies at the next connection.")
            }
            Section {
                Toggle(isOn: $settings.alignKeepalives) {
                    Text("Align keepalives")
                }
                .accessibilityIdentifier("settings.transport.alignKeepalives")
            } footer: {
                Text("Sends every connection's keepalive at the same moments, every 10 seconds, so the radio wakes once for all of them instead of for each. Applies at the next connection.")
            }
            Section {
                Toggle(isOn: $settings.lanDirect) {
                    Text("Direct on Wi-Fi")
                }
                .accessibilityIdentifier("settings.transport.lanDirect")
            } footer: {
                Text("Talk to your Mac directly when you share a network. Off: always use the relay.")
            }
            Section {
                Toggle(isOn: $settings.quietCloudConnect) {
                    Text("Quiet Cloud Connections")
                }
                .accessibilityIdentifier("settings.transport.quietCloudConnect")
            } footer: {
                Text("Cloud chats and machines that answer within 10 seconds show no loading or connecting message, and a short outage behind Cloud lists you already see shows no alert. Longer waits and failures still show.")
            }
            Section {
                Toggle(isOn: $settings.agentCLIHybrid) {
                    Text("Agent CLI Screen Changes")
                }
                .accessibilityIdentifier("settings.transport.agentCLIHybrid")
            } footer: {
                Text("A terminal running an agent CLI such as Claude Code or Codex, or a plain shell, comes from your Mac as the parts of its screen that changed, at most 10 times a second, instead of everything it writes. Full-screen programs still come as they are. It looks the same and uses less data. Applies when a terminal opens or reconnects.")
            }
            Section {
                Toggle(isOn: $settings.macScreenOverLink) {
                    Text("Mac Screen over Link")
                }
                .accessibilityIdentifier("settings.transport.macScreenOverLink")
            } footer: {
                Text("Screen Sharing shows a Mac's screen over the connection this iPhone already has to it, view only, when the Mac offers it. Otherwise, or if that stream fails, it connects the usual way. Applies when you open a Mac.")
            }
            #if !DEBUG
            Section {
                TransportDetails(store: store)
            }
            #endif
            #if DEBUG
            // No icons, as the transport choices above: the page keeps one text column.
            Section {
                TransportDetails(store: store, explainsDeveloperOptions: true)
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
                // The last resort on its own: cmux's WebSocket relay over HTTPS, at the next connection.
                Toggle(isOn: $forceRelay) {
                    Text("Relay via cmux (HTTPS) only")
                }
                .accessibilityIdentifier("settings.transport.forceRelay")
                Toggle(isOn: $proxyOnly) {
                    Text("Proxy only")
                }
                .accessibilityIdentifier("settings.transport.proxyOnly")
                Toggle(isOn: $dropWireGuard) {
                    Text("Drop WireGuard")
                }
                .accessibilityIdentifier("settings.transport.dropWireGuard")
                Toggle(isOn: $browserVideoOnChannel) {
                    Text("Browser video on channel")
                }
                .accessibilityIdentifier("settings.transport.browserVideoOnChannel")
                Toggle(isOn: $paintLatencyOverlay) {
                    Text("Paint latency overlay")
                }
                .accessibilityIdentifier("settings.transport.paintLatencyOverlay")
            } header: {
                Text("Developer")
            }
            #endif
        }
        .settingsPage("Transport")
    }

}

/// Live connection information is available on demand without filling normal status lines.
struct TransportDetails: View {
    let store: AppStore
    var explainsDeveloperOptions = false
    #if DEBUG
    @State private var expanded = UserDefaults.standard.bool(forKey: "cmux-mobile-transport-details")
    #else
    @State private var expanded = false
    #endif

    var body: some View {
        DisclosureGroup("Connection details", isExpanded: $expanded) {
            if store.macLinkDiagnostics.isEmpty {
                Text("No active connections.")
                    .foregroundStyle(theme.colors.label2)
            } else {
                ForEach(store.macLinkDiagnostics.keys.sorted(), id: \.self) { macID in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: store.teams.lazy.flatMap(\.macs).first(where: { $0.id == macID })?.name ?? String(localized: "Mac"))
                            .font(theme.type.rowTitle)
                        InPlaceSelectionLabel(store.macLinkDiagnostics[macID] ?? "", textStyle: .footnote,
                                              color: theme.colors.label2.uiColor)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            #if DEBUG
            if explainsDeveloperOptions {
                Text("Relay only forces TURN. Block UDP uses TURN over TLS for WireGuard; WebRTC is unchanged. Both reconnect immediately.")
                    .font(theme.type.meta)
                    .foregroundStyle(theme.colors.label2)
                Text("Proxy only blocks UDP and lets TURN over TLS out only through the system's proxy. Drop WireGuard drops WireGuard over UDP while STUN still answers, as a firewall that inspects packets. Both apply at the next connection.")
                    .font(theme.type.meta)
                    .foregroundStyle(theme.colors.label2)
                Text("Browser video on channel skips the media lane at the next connection.")
                    .font(theme.type.meta)
                    .foregroundStyle(theme.colors.label2)
            }
            #endif
        }
        .accessibilityIdentifier("settings.transport.details")
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
            Acknowledgement("Geist", "SIL OFL 1.1", "The welcome screen's wordmark and tagline", "https://github.com/vercel/geist-font"),
        ]),
    ]
}
#endif

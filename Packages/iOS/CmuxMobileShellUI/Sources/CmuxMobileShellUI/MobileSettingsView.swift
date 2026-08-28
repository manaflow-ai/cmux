#if os(iOS)
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileToast
import CmuxMobileWorkspace
import SwiftUI

/// The mobile app's settings page. Surfaces the signed-in account (so the user
/// can confirm which cmux account this device uses — the account must match the
/// Mac it pairs with), plus terminal shortcuts, agent notifications, and the
/// paired Mac. Presented as a sheet from the workspace list.
struct MobileSettingsView: View {
    /// Shared with `UserDefaultsAnalyticsConsentProvider`; keep the string stable
    /// so Settings controls the same gate used by analytics and crash reporting.
    private static let sendAnonymousTelemetryKey = "sendAnonymousTelemetry"

    @Environment(AuthCoordinator.self) private var authManager
    @Environment(MobilePushCoordinator.self) private var pushCoordinator
    @Environment(MobileDisplaySettings.self) private var displaySettings
    /// Optional so previews and hosts without the app root still render; the
    /// Connection Method section is hidden when absent.
    @Environment(MobileConnectionMethodStore.self) private var connectionMethodStore:
        MobileConnectionMethodStore?
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.mobileDiagnosticLog) private var diagnosticLog
    let connectedHostName: String
    let startPairingScanner: (() -> Void)?
    let signOut: (() -> Void)?
    /// The shell store, used for the live connection rows and the onboarding
    /// replay's connection state. `nil` in previews.
    var store: CMUXMobileShellStore?
    /// An optional row that should be visible immediately on presentation.
    var initialFocus: MobileSettingsFocus? = nil
    /// Lets the root modal coordinator advance directly to queued content.
    var dismissAction: (() -> Void)? = nil
    @AppStorage(MobileSettingsView.sendAnonymousTelemetryKey) private var sendAnonymousTelemetry = false

    @Environment(\.dismiss) private var dismiss
    @State private var showingShortcuts = false
    /// Mirrors ``MobilePushCoordinator/isEnabled`` so the toggle's label/icon
    /// update after the async enable/disable. The coordinator exposes
    /// `isEnabled` as a non-observable `UserDefaults` read, so reading it
    /// directly in `body` would not re-render when it flips.
    @State private var notificationsEnabled = false
#if DEBUG
    @State private var debugReplyScheduled: Bool?
#endif
    @State private var showingOnboarding = false
    @State private var showingSetupHelp = false
    @State private var caffeineStatusLoadFailed = false
    @State private var caffeineStatusRetryID = 0
    #if DEBUG
    @State private var showingToastGallery = false
    /// Seconds between tapping "Run Toast Demo" and the first toast, so you
    /// can navigate to any screen (terminal, chat) and watch it play there.
    @AppStorage("cmux.debug.toastDemoDelaySeconds") private var toastDemoDelaySeconds = 3
    #endif

    var body: some View {
        @Bindable var displaySettings = displaySettings
        return NavigationStack {
            settingsContent
        }
        .onChange(of: connectionMethodStore?.method) { oldMethod, newMethod in
            guard oldMethod != newMethod, store != nil else { return }
            let stackUserID = authManager.currentUser?.id
            Task {
                _ = await store?.retryActiveMacReconnect(
                    stackUserID: stackUserID,
                    force: true
                )
            }
        }
        .accessibilityIdentifier("MobileSettingsView")
        .onAppear {
            diagnosticLog?.recordAppEvent(.settingsOpened)
        }
        .onDisappear {
            diagnosticLog?.recordAppEvent(.settingsClosed)
        }
        .onChange(of: sendAnonymousTelemetry) { _, value in
            recordBooleanSetting(.telemetrySharingChanged, value)
            diagnosticLog?.recordAppEvent(
                .crashReportingConsentChanged,
                count: value ? 1 : 0
            )
        }
    }

    /// The Form and its modifier chain, extracted so `body` stays inside
    /// the type checker's budget.
    @ViewBuilder
    private var settingsContent: some View {
        @Bindable var displaySettings = displaySettings
            Form {
                settingsSectionsTop
                settingsSectionsBottom
            }
            .task {
                notificationsEnabled = pushCoordinator.isEnabled
                await pushCoordinator.refreshReadiness()
            }
            .onChange(of: pushCoordinator.isEnabled) { _, enabled in
                notificationsEnabled = enabled
            }
            .navigationTitle(L10n.string("mobile.workspaces.settings", defaultValue: "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.settings.done", defaultValue: "Done")) {
                        requestDismissal()
                    }
                    .accessibilityIdentifier("MobileSettingsDone")
                }
            }
            .sheet(isPresented: $showingShortcuts) {
                TerminalShortcutsSettingsView()
            }
            #if DEBUG
            .sheet(isPresented: $showingToastGallery) {
                ToastGalleryView()
            }
            #endif
            .sheet(isPresented: $showingOnboarding) {
                // Re-entry never writes first-run progress. The final scene reads
                // live connection state and can reopen pairing from offline Settings.
                OnboardingFlowView(
                    initialStage: .agents,
                    context: .replay,
                    isAuthenticated: true,
                    connectionPhase: OnboardingConnectionPhase(
                        isMacReady: store?.connectionState == .connected,
                        isSearching: store?.isReconnectingStoredMac == true,
                        didFinishSearch: store?.didFinishStoredMacReconnectAttempt == true
                    ),
                    connectionMethod: connectionMethodStore?.method ?? .relay,
                    onSelectConnectionMethod: { connectionMethodStore?.method = $0 },
                    onEnablePush: {
                        await pushCoordinator.enable(trigger: "onboarding_replay")
                    },
                    onReachedConnection: {},
                    onSkip: { showingOnboarding = false },
                    onRetryConnection: retryAutomaticConnection,
                    onStartTailscalePairing: {
                        showingOnboarding = false
                        startPairingScanner?()
                    },
                    onComplete: { showingOnboarding = false }
                )
            }
            .sheet(isPresented: $showingSetupHelp) {
                // Re-enterable setup help as a plain reference: every pre-pairing
                // gate with its concrete next step. Settings is reached only from
                // the connected workspace list, so there is no current blocker to
                // mark "You are here".
                SetupHelpView(highlight: setupHelpHighlight) { showingSetupHelp = false }
            }
    }


    private func recordBooleanSetting(
        _ kind: DiagnosticAppEventKind,
        _ value: Bool
    ) {
        diagnosticLog?.recordAppEvent(kind, count: value ? 1 : 0)
    }

    /// Closes through the owning modal coordinator when one is provided.
    private func requestDismissal() {
        if let dismissAction {
            dismissAction()
        } else {
            dismiss()
        }
    }

    private func activeTransportName(_ kind: CmxAttachTransportKind) -> String {
        switch kind {
        case .tailscale:
            L10n.string(
                "mobile.settings.activeTransport.tailscale",
                defaultValue: "Tailscale"
            )
        case .iroh:
            L10n.string(
                "mobile.settings.activeTransport.iroh",
                defaultValue: "Iroh"
            )
        case .websocket:
            L10n.string(
                "mobile.settings.activeTransport.websocket",
                defaultValue: "WebSocket"
            )
        case .debugLoopback:
            L10n.string(
                "mobile.settings.activeTransport.simulator",
                defaultValue: "Simulator"
            )
        }
    }

    @MainActor
    private func setPhonePushEnabledIntent(_ enabled: Bool) {
        diagnosticLog?.recordAppEvent(
            .notificationPreferenceChanged,
            count: enabled ? 1 : 0
        )
        pushCoordinator.setEnabledIntent(enabled)
    }

    @MainActor
    private func updatePhonePushEnabled(_ enabled: Bool) async -> Bool {
        diagnosticLog?.recordAppEvent(
            .notificationPreferenceChanged,
            count: enabled ? 1 : 0
        )
        if enabled {
            _ = await pushCoordinator.enable()
            // A denied OS authorization still accepts the user's app-level
            // intent. Keep the toggle on so readiness can surface the Settings
            // recovery action instead of rolling the preference back.
            return pushCoordinator.isEnabled
        }
        await pushCoordinator.disable()
        return !pushCoordinator.isEnabled
    }

    @MainActor
    private func repairPhonePush(
        _ repair: MobilePushReadiness.Repair
    ) async -> Bool {
        switch repair {
        case .enableOnPhone:
            return await updatePhonePushEnabled(true)
        case .openSystemSettings:
            pushCoordinator.openSystemSettings()
            return true
        case .retryDeviceTokenRegistration:
            pushCoordinator.retryDeviceTokenRegistration()
            await pushCoordinator.refreshReadiness()
            return true
        case .retryRegistration:
            await pushCoordinator.syncTokenIfPossible()
            await pushCoordinator.refreshReadiness()
            return true
        case .signInAgain, .signIntoMatchingAccount:
            signOut?()
            return signOut != nil
        case .connectMac:
            startPairingScanner?()
            return startPairingScanner != nil
        case .leaveMacOrUseAlwaysMode:
            return await store?.updatePhonePushSettings(mode: .always) == true
        case .enableOnMac:
            return await store?.updatePhonePushSettings(
                forwardingEnabled: true
            ) == true
        case .waitForDeviceToken, .finishAccountDeletion,
             .disablePushOnAnotherDevice, .rebuildMatchingApps:
            return false
        }
    }

    @MainActor
    private func updateMacPhonePush(
        _ mutation: MobilePushMacMutation
    ) async -> Bool {
        guard let store else { return false }
        switch mutation {
        case let .forwardingEnabled(enabled):
            return await store.updatePhonePushSettings(
                forwardingEnabled: enabled
            )
        case let .mode(mode):
            return await store.updatePhonePushSettings(mode: mode)
        case let .hideContent(hidden):
            return await store.updatePhonePushSettings(hideContent: hidden)
        }
    }

    @MainActor
    private func sendPhonePushTest() async -> MobilePhonePushTestStage {
        diagnosticLog?.recordAppEvent(.phonePushTestStarted)
        let stage = await store?.sendPhonePushTest() ?? .unavailable
        if stage == .queuedOnMac {
            diagnosticLog?.recordAppEvent(.phonePushTestSucceeded)
        } else {
            diagnosticLog?.recordAppEvent(
                .phonePushTestFailed,
                failure: stage == .authenticationUnavailable
                    ? .authorizationFailed
                    : .protocolViolation
            )
        }
        return stage
    }

    private static var crashReportingEnabled: Bool {
        switch Bundle.main.object(forInfoDictionaryKey: "CMUXCrashReportingEnabled") {
        case let enabled as Bool:
            enabled
        case let enabled as String:
            enabled.caseInsensitiveCompare("NO") != .orderedSame
        default:
            true
        }
    }

    private func retryAutomaticConnection() {
        guard let store else { return }
        let stackUserID = authManager.currentUser?.id
        Task {
            _ = await store.retryActiveMacReconnect(stackUserID: stackUserID)
        }
    }

    /// Which setup gate to mark as the user's current blocker. Settings is reached
    /// only from the connected workspace list, so the user has cleared every gate
    /// and there is no "You are here" step; the help is a plain reference. `nil`
    /// keeps that honest instead of mislabeling a connected Mac as unreachable.
    private var setupHelpHighlight: MobileSetupGuidanceState? {
        nil
    }

    /// Whether the Connection section has any rows to show. When nothing is
    /// connected the section is omitted entirely so its header never sits empty.
    private var hasConnectionRows: Bool {
        store?.liveMacConnections.isEmpty == false || !connectedHostName.isEmpty
    }

    /// Whether the setup and introduction entries apply. When this sheet is
    /// reused from the no-devices screen there is no connected Mac or store,
    /// so they are hidden.
    private var hasConnectionSection: Bool {
        !connectedHostName.isEmpty || store != nil
    }

    private var caffeineLoadID: String {
        guard let store else { return "disconnected" }
        return [
            store.connectedMacDeviceID ?? "unknown",
            String(store.supportsCaffeineControl),
            String(describing: store.connectionState),
        ].joined(separator: ":")
    }

    @ViewBuilder
    private var caffeineSettingsSection: some View {
        if let store, store.connectionState == .connected {
            MobileCaffeineSettingsContent(
                isEnabled: store.caffeineStatus?.enabled,
                isSupported: store.supportsCaffeineControl,
                isBusy: store.isCaffeineMutationInFlight,
                statusLoadFailed: caffeineStatusLoadFailed,
                onRetryStatus: {
                    caffeineStatusLoadFailed = false
                    caffeineStatusRetryID &+= 1
                },
                onSet: { enabled in
                    await store.setCaffeineEnabled(enabled)
                }
            )
            .task(id: "\(caffeineLoadID):\(caffeineStatusRetryID)") {
                let loadID = caffeineLoadID
                guard store.supportsCaffeineControl else {
                    caffeineStatusLoadFailed = false
                    return
                }
                caffeineStatusLoadFailed = false
                let didLoad = await store.refreshCaffeineStatus()
                guard !Task.isCancelled, caffeineLoadID == loadID else { return }
                caffeineStatusLoadFailed = !didLoad
            }
        }
    }

    /// Drives the team Picker. Reads the EFFECTIVE current team (`resolvedTeamID`,
    /// which falls back to the first team when nothing is explicitly selected) so
    /// the picker always shows a concrete selection, and writes the user's choice
    /// to `selectedTeamID` (persisted; observed by the root for the lazy re-scope).
    private var teamSelection: Binding<String?> {
        Binding(
            get: { authManager.resolvedTeamID },
            set: { newValue in
                if let newValue, newValue != authManager.selectedTeamID {
                    authManager.selectedTeamID = newValue
                }
            }
        )
    }

    #if DEBUG
    private func debugLayoutSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(debugPointValue(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 1)
        }
        .accessibilityIdentifier(identifier)
    }

    private func debugPointValue(_ value: Double) -> String {
        String(
            format: L10n.string("mobile.settings.pointsFormat", defaultValue: "%lld pt"),
            Int64(value.rounded())
        )
    }
    #endif


    /// First half of the settings sections. Split from the Form body because
    /// the single inline expression exceeded the type checker's budget.
    @ViewBuilder
    private var settingsSectionsTop: some View {
        @Bindable var displaySettings = displaySettings
                MobileSettingsAccountSection(signOut: signOut)

                // Directly under the account card so release notices stay
                // discoverable after their one-time launch sheet is
                // dismissed (HIG: keep skippable onboarding-style content
                // findable in a settings area).
                Section {
                    NavigationLink {
                        MobileWhatsNewListView()
                    } label: {
                        Label(
                            L10n.string("mobile.settings.whatsNew", defaultValue: "What's New"),
                            systemImage: "megaphone"
                        )
                    }
                    .accessibilityIdentifier("MobileSettingsWhatsNewRow")
                }

                // Stack team switcher. Only shown when the user belongs to more than
                // one team. Rendered as an INLINE picker — each team is a row with a
                // checkmark on the current one — so every team is visible at a glance
                // and one tap switches (clearer than a menu/navigation push for a
                // small set). Selecting a team writes `selectedTeamID`, which the root
                // view observes to re-scope the team-bound surfaces (paired Macs,
                // presence, backup) to that team without dropping the live terminal.
                if authManager.availableTeams.count > 1 {
                    Section {
                        Picker(selection: teamSelection) {
                            ForEach(authManager.availableTeams) { team in
                                Text(team.displayName).tag(team.id as String?)
                            }
                        } label: {
                            EmptyView()
                        }
                        .pickerStyle(.inline)
                        .accessibilityIdentifier("MobileSettingsTeamPicker")
                    } header: {
                        Label(
                            L10n.string("mobile.settings.team", defaultValue: "Team"),
                            systemImage: "person.2"
                        )
                    } footer: {
                        Text(L10n.string(
                            "mobile.settings.teamFooter",
                            defaultValue: "Switches which cmux team's computers and devices this app shows."
                        ))
                    }
                }

                // Hidden when there is no live connection row to show, so the
                // no-devices screen's reuse of this sheet does not render an
                // empty header. Switching Macs lives in the workspace list's
                // computer picker.
                if hasConnectionRows {
                    Section(L10n.string("mobile.settings.connection", defaultValue: "Connection")) {
                        if let connections = store?.liveMacConnections,
                           !connections.isEmpty {
                            ForEach(connections) { connection in
                                LabeledContent(
                                    connection.displayName,
                                    value: connection.role == .focused
                                        ? L10n.string(
                                            "mobile.settings.connectionFocused",
                                            defaultValue: "Focused"
                                        )
                                        : L10n.string(
                                            "mobile.settings.connectionReady",
                                            defaultValue: "Ready"
                                        )
                                )
                                .accessibilityIdentifier(
                                    "MobileSettingsMacConnection-\(connection.macDeviceID)"
                                )
                            }
                        } else if !connectedHostName.isEmpty {
                            LabeledContent(
                                L10n.string("mobile.settings.mac", defaultValue: "Connection"),
                                value: connectedHostName
                            )
                        }
                        if let store,
                           store.connectionState == .connected,
                           let routeKind = store.activeRoute?.kind {
                            LabeledContent(
                                L10n.string(
                                    "mobile.settings.activeTransport",
                                    defaultValue: "Active Transport"
                                ),
                                value: activeTransportName(routeKind)
                            )
                            .accessibilityIdentifier("MobileSettingsActiveTransport")
                        }
                    }
                }
                caffeineSettingsSection
                if hasConnectionSection {
                    Button {
                        showingSetupHelp = true
                    } label: {
                        Label(
                            L10n.string("mobile.settings.setUpYourMac", defaultValue: "Set Up Computer"),
                            systemImage: "macbook.and.iphone"
                        )
                    }
                    .accessibilityIdentifier("MobileSettingsSetUpYourMac")
                    Button {
                        showingOnboarding = true
                    } label: {
                        Label(
                            L10n.string(
                                "mobile.settings.viewIntroductionAgain",
                                defaultValue: "View Introduction Again"
                            ),
                            systemImage: "sparkles"
                        )
                    }
                    .accessibilityIdentifier("MobileSettingsHowPairingWorks")
                }


                Section(L10n.string("mobile.settings.terminal", defaultValue: "Terminal")) {
                    Toggle(isOn: $displaySettings.showAltScreenNotice) {
                        Text(L10n.string(
                            "mobile.settings.altScreenNotice",
                            defaultValue: "Full-Screen Sizing Notice"
                        ))
                    }
                    .accessibilityIdentifier("MobileSettingsAltScreenNoticeToggle")

                    Toggle(isOn: $displaySettings.terminalFolderTapEnabled) {
                        Text(L10n.string(
                            "mobile.settings.terminalFolderTap",
                            defaultValue: "Open Folders on Tap"
                        ))
                    }
                    .accessibilityIdentifier("MobileSettingsTerminalFolderTapToggle")

                    Button {
                        showingShortcuts = true
                    } label: {
                        Label(
                            L10n.string("mobile.workspaces.terminalShortcuts", defaultValue: "Terminal Shortcuts"),
                            systemImage: "keyboard"
                        )
                    }
                    .accessibilityIdentifier("MobileSettingsTerminalShortcuts")
                }

                Section {
                    Toggle(isOn: $displaySettings.hapticFeedbackEnabled) {
                        Text(L10n.string(
                            "mobile.settings.hapticFeedback",
                            defaultValue: "Haptic Feedback"
                        ))
                    }
                    .accessibilityIdentifier("MobileSettingsHapticFeedbackToggle")
                } header: {
                    Text(L10n.string("mobile.settings.haptics", defaultValue: "Haptics"))
                } footer: {
                    Text(L10n.string(
                        "mobile.settings.hapticFeedbackFooter",
                        defaultValue: "When off, cmux does not vibrate for actions, confirmations, warnings, or errors."
                    ))
                }

                #if DEBUG
                Section(L10n.string("mobile.settings.developer", defaultValue: "Developer")) {
                    Button {
                        showingToastGallery = true
                    } label: {
                        Label(
                            L10n.string("mobile.settings.toastGallery", defaultValue: "Toast Gallery"),
                            systemImage: "rectangle.portrait.topthird.inset.filled"
                        )
                    }
                    .accessibilityIdentifier("MobileSettingsToastGallery")
                    Button {
                        ToastDemo.run(on: toasts, after: .seconds(toastDemoDelaySeconds))
                        requestDismissal()
                    } label: {
                        Label(
                            L10n.string("mobile.settings.toastDemo", defaultValue: "Run Toast Demo"),
                            systemImage: "play.rectangle"
                        )
                    }
                    .accessibilityIdentifier("MobileSettingsToastDemo")
                    Stepper(value: $toastDemoDelaySeconds, in: 0...30) {
                        HStack {
                            Text(L10n.string(
                                "mobile.settings.toastDemoDelay",
                                defaultValue: "Toast Demo Delay"
                            ))
                            Spacer()
                            Text(String.localizedStringWithFormat(
                                L10n.string(
                                    "mobile.settings.toastDemoDelayValueFormat",
                                    defaultValue: "%d s"
                                ),
                                toastDemoDelaySeconds
                            ))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("MobileSettingsToastDemoDelay")

                    debugLayoutSlider(
                        title: L10n.string(
                            "mobile.settings.unreadIndicatorLeftness",
                            defaultValue: "Unread Indicator Leftness"
                        ),
                        value: $displaySettings.unreadIndicatorLeftShift,
                        range: MobileDisplaySettings.unreadIndicatorLeftShiftRange,
                        identifier: "MobileSettingsUnreadIndicatorLeftness"
                    )

                    Toggle(isOn: $displaySettings.forceRebuildKeyboardDock) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.string(
                                "mobile.settings.rebuildKeyboardDock",
                                defaultValue: "Rebuilt Keyboard Pinning"
                            ))
                            Text(L10n.string(
                                "mobile.settings.rebuildKeyboardDockCaption",
                                defaultValue: "Use the rebuilt keyboard path instead of the default (iOS 26 and earlier). Reopen the workspace to apply."
                            ))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("MobileSettingsRebuildKeyboardDock")
                }

                Section(L10n.string(
                    "mobile.settings.cmuxLabs",
                    defaultValue: "CMUX Labs"
                )) {
                    NavigationLink {
                        TaskComposerShellIconLabView()
                    } label: {
                        Label(
                            L10n.string(
                                "mobile.settings.shellIconLab",
                                defaultValue: "Shell Icon Lab"
                            ),
                            systemImage: "terminal"
                        )
                    }
                    .accessibilityIdentifier("MobileSettingsShellIconLab")

                    NavigationLink {
                        UnreadIndicatorLabView()
                    } label: {
                        Label(
                            L10n.string(
                                "mobile.settings.unreadIndicatorLab",
                                defaultValue: "Unread Indicator Lab"
                            ),
                            systemImage: "circle.badge"
                        )
                    }
                    .accessibilityIdentifier("MobileSettingsUnreadIndicatorLab")
                }
                #endif
    }

    /// Second half of the settings sections (see `settingsSectionsTop`).
    @ViewBuilder
    private var settingsSectionsBottom: some View {
        @Bindable var displaySettings = displaySettings

                Section(L10n.string("mobile.settings.display", defaultValue: "Display")) {
                    Toggle(isOn: $displaySettings.showMissingFiles) {
                        Text(L10n.string(
                            "mobile.settings.showMissingFiles",
                            defaultValue: "Show missing files"
                        ))
                    }
                    .accessibilityIdentifier("MobileSettingsShowMissingFiles")

                    Toggle(isOn: $displaySettings.wrapWorkspaceTitles) {
                        Text(L10n.string("mobile.settings.wrapTitles", defaultValue: "Wrap Workspace Titles"))
                    }
                    .accessibilityIdentifier("MobileSettingsWrapTitles")

                    Picker(selection: $displaySettings.workspacePreviewLineCount) {
                        Text(L10n.string("mobile.settings.previewLines.one", defaultValue: "1 Line"))
                            .tag(1)
                        Text(L10n.string("mobile.settings.previewLines.two", defaultValue: "2 Lines"))
                            .tag(2)
                    } label: {
                        Text(L10n.string("mobile.settings.previewLines", defaultValue: "Preview Lines"))
                    }
                    .accessibilityIdentifier("MobileSettingsPreviewLines")

                    Picker(selection: $displaySettings.terminalScrollbackRows) {
                        Text(L10n.string("mobile.settings.terminalScrollback.rows1k", defaultValue: "1,000 Rows"))
                            .tag(1000)
                        Text(L10n.string("mobile.settings.terminalScrollback.rows4k", defaultValue: "4,000 Rows"))
                            .tag(4000)
                        Text(L10n.string("mobile.settings.terminalScrollback.rows10k", defaultValue: "10,000 Rows"))
                            .tag(10000)
                        Text(L10n.string("mobile.settings.terminalScrollback.rows20k", defaultValue: "20,000 Rows"))
                            .tag(20000)
                    } label: {
                        Text(L10n.string("mobile.settings.terminalScrollback", defaultValue: "Terminal Scrollback"))
                    }
                    .accessibilityIdentifier("MobileSettingsTerminalScrollback")
                }

                // Release builds keep the section to the single agent-alerts
                // toggle the app always had; the delivery-status diagnostics,
                // Mac forwarding controls, and test actions are a dev surface
                // and stay DEBUG-only.
                Section(L10n.string("mobile.settings.notifications", defaultValue: "Push Alerts")) {
#if DEBUG
                    MobilePushSettingsContent(
                        readiness: pushCoordinator.readiness(
                            macStatus: store?.phonePushMacStatus,
                            macAccountMismatch: store?.connectionRequiresReauth == true
                        ),
                        phoneEnabled: $notificationsEnabled,
                        macStatus: store?.phonePushMacStatus,
                        supportsMacSettings: store?.supportsPhonePushSettings == true,
                        supportsMacTest: store?.supportsPhonePushTest == true,
                        canConnectMac: startPairingScanner != nil,
                        onPhoneEnabledChange: updatePhonePushEnabled,
                        onRepair: repairPhonePush,
                        onMacMutation: updateMacPhonePush,
                        onSendTest: sendPhonePushTest
                    )
                    Button {
                        Task { @MainActor in
                            debugReplyScheduled = await pushCoordinator
                                .debugScheduleLocalReplyNotification()
                        }
                    } label: {
                        Text(L10n.string(
                            "mobile.settings.debugReplyTest",
                            defaultValue: "Test Inline Reply (Local)"
                        ))
                    }
                    .accessibilityIdentifier("MobileSettingsDebugReplyTestButton")
                    if let debugReplyScheduled {
                        Text(L10n.string(
                            debugReplyScheduled
                                ? "mobile.settings.debugReplyTest.scheduled"
                                : "mobile.settings.debugReplyTest.failed",
                            defaultValue: debugReplyScheduled
                                ? "Scheduled: lock the phone; the notification fires in 5 seconds."
                                : "Couldn't schedule: open a workspace and select a terminal first."
                        ))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
#else
                    MobilePushToggle(
                        isEnabled: $notificationsEnabled,
                        applyEnabledIntent: setPhonePushEnabledIntent
                    )
#endif
                }

                Section {
                    Toggle(isOn: $sendAnonymousTelemetry) {
                        Text(L10n.string(
                            Self.crashReportingEnabled
                                ? "mobile.settings.telemetry"
                                : "mobile.settings.telemetryAnalyticsOnly",
                            defaultValue: Self.crashReportingEnabled
                                ? "Share Analytics and Crash Reports"
                                : "Share Anonymous Analytics"
                        ))
                    }
                    .accessibilityIdentifier("MobileSettingsTelemetryToggle")
                } header: {
                    Text(L10n.string("mobile.settings.privacy", defaultValue: "Privacy"))
                } footer: {
                    Text(L10n.string(
                        Self.crashReportingEnabled
                            ? "mobile.settings.telemetryFooter"
                            : "mobile.settings.telemetryAnalyticsOnlyFooter",
                        defaultValue: Self.crashReportingEnabled
                            ? "When off, cmux does not send iPhone or iPad product analytics or crash reports."
                            : "When off, cmux does not send iPhone or iPad product analytics."
                    ))
                }

                MobileSettingsDiagnosticsSection()

                MobileSettingsLegalSupportSection()

                Section(L10n.string("mobile.settings.about", defaultValue: "About")) {
                    LabeledContent {
                        Text(AppVersionInfo.current().displayString)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } label: {
                        Label(
                            L10n.string("mobile.settings.version", defaultValue: "Version"),
                            systemImage: "info.circle"
                        )
                    }
                    .accessibilityIdentifier("MobileSettingsVersionRow")
                }
    }
}

/// App-wide log sharing. Lives at the settings top level, not the Iroh
/// screen: the app log covers every feature (simulator, browser, composer,
/// lifecycle), and the network log covers all connection diagnostics, not
/// one transport.
private struct MobileSettingsDiagnosticsSection: View {
    @State private var appLogURLs: [URL] = []
    @State private var networkLogURLs: [URL] = []

    var body: some View {
        Section {
            if !appLogURLs.isEmpty {
                ShareLink(items: appLogURLs) {
                    Label(
                        L10n.string(
                            "mobile.settings.diagnostics.shareAppLog",
                            defaultValue: "Share App Log"
                        ),
                        systemImage: "doc.text"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("MobileSettingsShareAppLog")
            }
            if !networkLogURLs.isEmpty {
                ShareLink(items: networkLogURLs) {
                    Label(
                        L10n.string(
                            "mobile.settings.diagnostics.shareNetworkLog",
                            defaultValue: "Share Network Log"
                        ),
                        systemImage: "network"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("MobileSettingsShareNetworkLog")
            }
        } header: {
            Text(L10n.string("mobile.settings.diagnostics", defaultValue: "Diagnostics"))
        } footer: {
            Text(L10n.string(
                "mobile.settings.diagnostics.footer",
                defaultValue: "The App Log records in-app activity; the Network Log records connection diagnostics. Terminal contents and credentials are never written."
            ))
        }
        .task {
            let urls = await Task.detached(priority: .utility) {
                (AppLog.appLogFileURLs, AppLog.networkLogFileURLs)
            }.value
            appLogURLs = urls.0
            networkLogURLs = urls.1
        }
    }

}
#endif

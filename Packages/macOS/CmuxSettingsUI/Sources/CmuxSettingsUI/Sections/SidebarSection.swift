import CmuxFoundation
import CmuxSettings
import SwiftUI

/// **Sidebar** section — mirrors the legacy workspace-row detail
/// toggles. Rows that depend on a parent toggle (`hideAllDetails`, PR
/// visibility, PR clickability) are disabled accordingly.
@MainActor
public struct SidebarSection: View {
    private let rightSidebarWidthSettings = RightSidebarWidthSettings()

    @State private var hideAll: DefaultsValueModel<Bool>
    @State private var wrapTitles: DefaultsValueModel<Bool>
    @State private var showDesc: DefaultsValueModel<Bool>
    @State private var branchVerticalLayout: DefaultsValueModel<Bool>
    @State private var stackBranchDir: DefaultsValueModel<Bool>
    @State private var pathLastOnly: DefaultsValueModel<Bool>
    @State private var showNotification: DefaultsValueModel<Bool>
    @State private var showBranchDir: DefaultsValueModel<Bool>
    @State private var showPR: DefaultsValueModel<Bool>
    @State private var watchGit: DefaultsValueModel<Bool>
    @State private var prClickable: DefaultsValueModel<Bool>
    @State private var prLinks: DefaultsValueModel<Bool>
    @State private var portLinks: DefaultsValueModel<Bool>
    @State private var showSSH: DefaultsValueModel<Bool>
    @State private var showPorts: DefaultsValueModel<Bool>
    @State private var showLog: DefaultsValueModel<Bool>
    @State private var showProgress: DefaultsValueModel<Bool>
    @State private var showMetadata: DefaultsValueModel<Bool>
    @State private var rightMaxWidth: DefaultsValueModel<Double>
    @State private var rememberedRightMaxWidth: DefaultsValueModel<Double>

    /// Creates the Sidebar settings section.
    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _hideAll = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.hideAllDetails))
        _wrapTitles = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.wrapWorkspaceTitles))
        _showDesc = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showWorkspaceDescription))
        _branchVerticalLayout = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.branchVerticalLayout))
        _stackBranchDir = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.stackBranchDirectory))
        _pathLastOnly = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.pathLastSegmentOnly))
        _showNotification = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showNotificationMessage))
        _showBranchDir = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showBranchDirectory))
        _showPR = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showPullRequests))
        _watchGit = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.watchGitStatus))
        _prClickable = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.makePullRequestsClickable))
        _prLinks = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.openPullRequestLinksInCmuxBrowser))
        _portLinks = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.openPortLinksInCmuxBrowser))
        _showSSH = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showSSH))
        _showPorts = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showPorts))
        _showLog = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showLog))
        _showProgress = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showProgress))
        _showMetadata = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showCustomMetadata))
        _rightMaxWidth = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.rightMaxWidth))
        _rememberedRightMaxWidth = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.rememberedRightMaxWidth))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.sidebarAppearance", defaultValue: "Sidebar"), section: .sidebarAppearance)
            mainCard
        }
        .task { startObservingSettings() }
    }

    private func startObservingSettings() {
        let models: [any SettingObservationStarting] = [
            hideAll,
            wrapTitles,
            showDesc,
            branchVerticalLayout,
            stackBranchDir,
            pathLastOnly,
            showNotification,
            showBranchDir,
            showPR,
            watchGit,
            prClickable,
            prLinks,
            portLinks,
            showSSH,
            showPorts,
            showLog,
            showProgress,
            showMetadata,
            rightMaxWidth,
            rememberedRightMaxWidth,
        ]
        models.forEach { $0.startObserving() }
    }

    private var rightMaxWidthOverrideEnabled: Bool {
        rightMaxWidth.current.isFinite && rightMaxWidth.current > 0
    }

    private var rightMaxWidthOverrideBinding: Binding<Bool> {
        Binding(
            get: { rightMaxWidthOverrideEnabled },
            set: { enabled in
                if enabled {
                    let restored = rightSidebarWidthSettings.storedMaximumWidthWhenEnabling(
                        rememberedStoredValue: rememberedRightMaxWidth.current
                    )
                    rememberedRightMaxWidth.set(restored)
                    rightMaxWidth.set(restored)
                } else {
                    rememberedRightMaxWidth.set(
                        rightSidebarWidthSettings.storedRememberedMaximumWidth(
                            activeStoredValue: rightMaxWidth.current,
                            rememberedStoredValue: rememberedRightMaxWidth.current
                        )
                    )
                    rightMaxWidth.set(RightSidebarWidthSettings.noOverrideValue)
                }
            }
        )
    }

    private var rightMaxWidthEditorBinding: Binding<Double> {
        Binding(
            get: {
                rightSidebarWidthSettings.editorMaximumWidth(
                    activeStoredValue: rightMaxWidth.current,
                    rememberedStoredValue: rememberedRightMaxWidth.current
                )
            },
            set: {
                let clamped = clampedRightMaxWidth($0)
                rememberedRightMaxWidth.set(clamped)
                if rightMaxWidthOverrideEnabled {
                    rightMaxWidth.set(clamped)
                }
            }
        )
    }

    private var rightMaxWidthSubtitle: String {
        if rightMaxWidthOverrideEnabled {
            return String(localized: "settings.sidebar.rightMaxWidth.subtitleOn", defaultValue: "The Dock can grow past the built-in width cap while preserving terminal space.")
        }
        return String(localized: "settings.sidebar.rightMaxWidth.subtitleOff", defaultValue: "Use the built-in dynamic cap that keeps extra terminal space reserved.")
    }

    private func clampedRightMaxWidth(_ value: Double) -> Double {
        rightSidebarWidthSettings.clampedSettingsEditorMaximumWidth(value)
    }

    @ViewBuilder
    private var mainCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("sidebar.rightMaxWidth"),
                String(localized: "settings.sidebar.rightMaxWidth", defaultValue: "Dock Max Width"),
                subtitle: rightMaxWidthSubtitle,
                controlWidth: 250
            ) {
                HStack(spacing: 8) {
                    Toggle("", isOn: rightMaxWidthOverrideBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel(String(localized: "settings.sidebar.rightMaxWidth.toggle", defaultValue: "Use custom Dock max width"))

                    TextField("", value: rightMaxWidthEditorBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                        .disabled(!rightMaxWidthOverrideEnabled)
                        .accessibilityLabel(String(localized: "settings.sidebar.rightMaxWidth", defaultValue: "Dock Max Width"))

                    Text(String(localized: "settings.sidebar.rightMaxWidth.unit", defaultValue: "pt"))
                        .foregroundStyle(.secondary)
                }
            }
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("sidebar.hideAllDetails"),
                String(localized: "settings.app.hideAllSidebarDetails", defaultValue: "Hide All Sidebar Details"),
                subtitle: hideAll.current
                    ? String(localized: "settings.app.hideAllSidebarDetails.subtitleOn", defaultValue: "Show only the workspace title row. Overrides the detail toggles below.")
                    : String(localized: "settings.app.hideAllSidebarDetails.subtitleOff", defaultValue: "Show secondary workspace details as controlled by the toggles below.")
            ) {
                Toggle("", isOn: Binding(get: { hideAll.current }, set: { hideAll.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("sidebar.wrapWorkspaceTitles"),
                String(localized: "settings.app.wrapWorkspaceTitles", defaultValue: "Wrap Workspace Titles in Sidebar"),
                subtitle: wrapTitles.current
                    ? String(localized: "settings.app.wrapWorkspaceTitles.subtitleOn", defaultValue: "Long workspace titles can use as many lines as they need.")
                    : String(localized: "settings.app.wrapWorkspaceTitles.subtitleOff", defaultValue: "Workspace titles stay on one line and truncate at the end.")
            ) {
                Toggle("", isOn: Binding(get: { wrapTitles.current }, set: { wrapTitles.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("sidebar.showWorkspaceDescription"),
                String(localized: "settings.app.showWorkspaceDescription", defaultValue: "Show Workspace Description in Sidebar"),
                subtitle: String(localized: "settings.app.showWorkspaceDescription.subtitle", defaultValue: "Display custom workspace descriptions below the workspace title.")
            ) {
                Toggle("", isOn: Binding(get: { showDesc.current }, set: { showDesc.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(hideAll.current)
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("sidebar.branchLayout"),
                String(localized: "settings.app.sidebarBranchLayout", defaultValue: "Sidebar Branch Layout"),
                subtitle: branchVerticalLayout.current
                    ? String(localized: "settings.app.sidebarBranchLayout.subtitleVertical", defaultValue: "Vertical: each branch appears on its own line.")
                    : String(localized: "settings.app.sidebarBranchLayout.subtitleInline", defaultValue: "Inline: all branches share one line."),
                controlWidth: 196
            ) {
                Picker("", selection: Binding(get: { branchVerticalLayout.current }, set: { branchVerticalLayout.set($0) })) {
                    Text(String(localized: "settings.app.sidebarBranchLayout.vertical", defaultValue: "Vertical")).tag(true)
                    Text(String(localized: "settings.app.sidebarBranchLayout.inline", defaultValue: "Inline")).tag(false)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .disabled(hideAll.current)
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("sidebar.stackBranchDirectory"),
                String(localized: "settings.app.stackBranchDirectory", defaultValue: "Stack Branch and Directory"),
                subtitle: stackBranchDir.current
                    ? String(localized: "settings.app.stackBranchDirectory.subtitleOn", defaultValue: "Branch and directory render on separate lines.")
                    : String(localized: "settings.app.stackBranchDirectory.subtitleOff", defaultValue: "Branch and directory share a single line.")
            ) {
                Toggle("", isOn: Binding(get: { stackBranchDir.current }, set: { stackBranchDir.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(hideAll.current)
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("sidebar.pathLastSegmentOnly"),
                String(localized: "settings.app.pathLastSegmentOnly", defaultValue: "Truncate Path From Start"),
                subtitle: pathLastOnly.current
                    ? String(localized: "settings.app.pathLastSegmentOnly.subtitleOn", defaultValue: "Show as much of the trailing path as fits; shorter forms are prefixed with …/.")
                    : String(localized: "settings.app.pathLastSegmentOnly.subtitleOff", defaultValue: "Render full paths abbreviated with ~/.")
            ) {
                Toggle("", isOn: Binding(get: { pathLastOnly.current }, set: { pathLastOnly.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(hideAll.current)
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("sidebar.showNotificationMessage"),
                String(localized: "settings.app.showNotificationMessage", defaultValue: "Show Notification Message in Sidebar"),
                subtitle: String(localized: "settings.app.showNotificationMessage.subtitle", defaultValue: "Display the latest notification message below the workspace title.")
            ) {
                Toggle("", isOn: Binding(get: { showNotification.current }, set: { showNotification.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(hideAll.current)
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("sidebar.showBranchDirectory"),
                String(localized: "settings.app.showBranchDirectory", defaultValue: "Show Branch + Directory in Sidebar"),
                subtitle: String(localized: "settings.app.showBranchDirectory.subtitle", defaultValue: "Display the built-in git branch and working-directory row.")
            ) {
                Toggle("", isOn: Binding(get: { showBranchDir.current }, set: { showBranchDir.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(hideAll.current)
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("sidebar.showPullRequests"),
                String(localized: "settings.app.showPullRequests", defaultValue: "Show Pull Requests in Sidebar"),
                subtitle: String(localized: "settings.app.showPullRequests.subtitle", defaultValue: "Display review items (PR/MR/etc.) with status and number.")
            ) {
                Toggle("", isOn: Binding(get: { showPR.current }, set: { showPR.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(hideAll.current)
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("sidebar.watchGitStatus"),
                String(localized: "settings.app.watchGitStatus", defaultValue: "Watch Git Status in Sidebar"),
                subtitle: String(localized: "settings.app.watchGitStatus.subtitle", defaultValue: "Update sidebar branch and PR metadata from repository file changes without polling git.")
            ) {
                Toggle("", isOn: Binding(get: { watchGit.current }, set: { watchGit.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(hideAll.current)
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("sidebar.makePullRequestsClickable"),
                String(localized: "settings.app.makeSidebarPullRequestClickable", defaultValue: "Make Sidebar PR Clickable"),
                subtitle: String(localized: "settings.app.makeSidebarPullRequestClickable.subtitle", defaultValue: "Review items stay visible as plain text, and clicks in that area select the workspace row.")
            ) {
                Toggle("", isOn: Binding(get: { prClickable.current }, set: { prClickable.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsSidebarPullRequestClickableToggle")
            }
            .disabled(hideAll.current || !showPR.current)
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("sidebar.openPullRequestLinksInCmuxBrowser"),
                String(localized: "settings.app.openSidebarPRLinks", defaultValue: "Open Sidebar PR Links in cmux Browser"),
                subtitle: prLinksSubtitle(prVisible: showPR.current, prClickable: prClickable.current, openInCmux: prLinks.current)
            ) {
                Toggle("", isOn: Binding(get: { prLinks.current }, set: { prLinks.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(hideAll.current || !showPR.current || !prClickable.current)
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("sidebar.openPortLinksInCmuxBrowser"),
                String(localized: "settings.app.openSidebarPortLinks", defaultValue: "Open Sidebar Port Links in cmux Browser"),
                subtitle: portLinks.current
                    ? String(localized: "settings.app.openSidebarPortLinks.subtitleOn", defaultValue: "Port clicks open inside cmux browser.")
                    : String(localized: "settings.app.openSidebarPortLinks.subtitleOff", defaultValue: "Port clicks open in your default browser.")
            ) {
                Toggle("", isOn: Binding(get: { portLinks.current }, set: { portLinks.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(hideAll.current)
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("sidebar.showSSH"),
                String(localized: "settings.app.showSSH", defaultValue: "Show SSH in Sidebar"),
                subtitle: String(localized: "settings.app.showSSH.subtitle", defaultValue: "Display the SSH target for remote workspaces in its own row.")
            ) {
                Toggle("", isOn: Binding(get: { showSSH.current }, set: { showSSH.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(hideAll.current)
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("sidebar.showPorts"),
                String(localized: "settings.app.showPorts", defaultValue: "Show Listening Ports in Sidebar"),
                subtitle: String(localized: "settings.app.showPorts.subtitle", defaultValue: "Display detected listening ports for the active workspace.")
            ) {
                Toggle("", isOn: Binding(get: { showPorts.current }, set: { showPorts.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(hideAll.current)
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("sidebar.showLog"),
                String(localized: "settings.app.showLog", defaultValue: "Show Latest Log in Sidebar"),
                subtitle: String(localized: "settings.app.showLog.subtitle", defaultValue: "Display the latest imperative log/status message.")
            ) {
                Toggle("", isOn: Binding(get: { showLog.current }, set: { showLog.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(hideAll.current)
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("sidebar.showProgress"),
                String(localized: "settings.app.showProgress", defaultValue: "Show Progress in Sidebar"),
                subtitle: String(localized: "settings.app.showProgress.subtitle", defaultValue: "Display the built-in progress bar from set_progress.")
            ) {
                Toggle("", isOn: Binding(get: { showProgress.current }, set: { showProgress.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(hideAll.current)
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("sidebar.showCustomMetadata"),
                String(localized: "settings.app.showMetadata", defaultValue: "Show Custom Metadata in Sidebar"),
                subtitle: String(localized: "settings.app.showMetadata.subtitle", defaultValue: "Display custom metadata from report_meta/set_status and report_meta_block.")
            ) {
                Toggle("", isOn: Binding(get: { showMetadata.current }, set: { showMetadata.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(hideAll.current)
        }
    }

    private func prLinksSubtitle(prVisible: Bool, prClickable: Bool, openInCmux: Bool) -> String {
        if !prVisible {
            return String(localized: "settings.app.openSidebarPRLinks.subtitleHidden", defaultValue: "Enable sidebar PR visibility to choose where PR links open.")
        }
        if !prClickable {
            return String(localized: "settings.app.openSidebarPRLinks.subtitleDisabled", defaultValue: "Enable sidebar PR clickability to choose where PR links open.")
        }
        return openInCmux
            ? String(localized: "settings.app.openSidebarPRLinks.subtitleOn", defaultValue: "Clicks open inside cmux browser.")
            : String(localized: "settings.app.openSidebarPRLinks.subtitleOff", defaultValue: "Clicks open in your default browser.")
    }
}

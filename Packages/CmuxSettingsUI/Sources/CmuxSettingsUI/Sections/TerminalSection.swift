import CmuxSettings
import SwiftUI

/// **Terminal** section — mirrors the legacy in-app section
/// row-for-row: scroll bar, copy on selection, resume agent sessions,
/// agent hibernation enable + idle seconds + max live terminals, plus
/// the JSON-backed Resume Commands editor.
@MainActor
public struct TerminalSection: View {
    private let jsonStore: JSONConfigStore
    private let catalog: SettingCatalog
    private let hostActions: SettingsHostActions

    @State private var surfaceTabBarFont: SettingsFontSize
    @State private var fontSaveFailed = false
    @State private var fontSaveTask: Task<Void, Never>?
    @State private var scrollBar: DefaultsValueModel<Bool>
    @State private var copyOnSelect: DefaultsValueModel<Bool>
    @State private var autoResume: DefaultsValueModel<Bool>
    @State private var hibernation: DefaultsValueModel<Bool>
    @State private var idleSeconds: DefaultsValueModel<Double>
    @State private var maxLive: DefaultsValueModel<Int>
    @State private var paneDividerColor: JSONValueModel<String>
    @State private var paneDividerThickness: JSONValueModel<Double>
    // Slider draft so dragging updates the label live and only persists (one
    // cmux.json write + one divider re-apply) when the drag ends.
    @State private var paneDividerThicknessDraft: Double = 1

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog,
        hostActions: SettingsHostActions
    ) {
        self.jsonStore = jsonStore
        self.catalog = catalog
        self.hostActions = hostActions
        _surfaceTabBarFont = State(initialValue: hostActions.surfaceTabBarFontSize())
        _scrollBar = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.showScrollBar))
        _copyOnSelect = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.copyOnSelect))
        _autoResume = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.autoResumeAgentSessions))
        _hibernation = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.agentHibernationEnabled))
        _idleSeconds = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.agentHibernationIdleSeconds))
        _maxLive = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.agentHibernationMaxLiveTerminals))
        _paneDividerColor = State(initialValue: JSONValueModel(store: jsonStore, key: catalog.ui.paneDividerColor, errorLog: errorLog))
        _paneDividerThickness = State(initialValue: JSONValueModel(store: jsonStore, key: catalog.ui.paneDividerThickness, errorLog: errorLog))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.terminal", defaultValue: "Terminal"), section: .terminal)
            mainCard
            paneDividerCard
            resumeCommandsCard
        }
    }

    /// Persists a new tab-bar font size, cancelling any in-flight save so a
    /// rapid sequence of slider releases only reflects the latest value (the
    /// host serializes the underlying writes; this keeps the UI state in step).
    private func saveSurfaceTabBarFontSize(_ points: Double) {
        fontSaveTask?.cancel()
        fontSaveTask = Task {
            let saved = await hostActions.setSurfaceTabBarFontSize(points)
            if !Task.isCancelled { fontSaveFailed = !saved }
        }
    }

    /// Maximum divider thickness offered in the UI. Matches the clamp in
    /// `PaneDividerStyle`/Bonsplit so the slider never produces a rejected
    /// value; advanced fractional values remain editable in cmux.json.
    private static let maxDividerThickness: Double = 12

    /// Formats a divider thickness for the value label: whole numbers show no
    /// decimal (`2`), half steps show one (`2.5`).
    private func formattedThickness(_ value: Double) -> String {
        let snapped = (value * 2).rounded() / 2
        return snapped == snapped.rounded()
            ? String(Int(snapped))
            : String(format: "%.1f", snapped)
    }

    @ViewBuilder
    private var paneDividerCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("ui.paneDivider.thickness"),
                String(localized: "settings.terminal.paneDividerThickness", defaultValue: "Pane Separator Thickness"),
                subtitle: String(
                    localized: "settings.terminal.paneDividerThickness.subtitle",
                    defaultValue: "Thickness, in points, of the bar between split panes. Defaults to a thin 1pt hairline; increase it to make the separator more visible."
                ),
                controlWidth: 250
            ) {
                HStack(spacing: 8) {
                    Slider(
                        value: $paneDividerThicknessDraft,
                        in: 0...Self.maxDividerThickness,
                        step: 0.5
                    ) { editing in
                        if !editing {
                            paneDividerThickness.set(paneDividerThicknessDraft)
                        }
                    }
                    .frame(width: 130)
                    .accessibilityIdentifier("SettingsPaneDividerThicknessSlider")

                    Text(String.localizedStringWithFormat(
                        String(localized: "settings.fontSize.valuePoints", defaultValue: "%@ pt"),
                        formattedThickness(paneDividerThicknessDraft)
                    ))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)

                    Button(String(localized: "settings.terminal.paneDividerThickness.reset", defaultValue: "Reset")) {
                        paneDividerThicknessDraft = 1
                        paneDividerThickness.reset()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(abs(paneDividerThicknessDraft - 1) < 0.001)
                }
            }
            .task { paneDividerThicknessDraft = paneDividerThickness.current }
            .onChange(of: paneDividerThickness.current) { _, newValue in
                paneDividerThicknessDraft = newValue
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("ui.paneDivider.color"),
                String(localized: "settings.terminal.paneDividerColor", defaultValue: "Pane Separator Color"),
                subtitle: paneDividerColor.current.isEmpty
                    ? String(localized: "settings.terminal.paneDividerColor.subtitleDefault", defaultValue: "Following the terminal theme (and the Ghostty split-divider-color). Pick a color to override it.")
                    : String(localized: "settings.terminal.paneDividerColor.subtitleCustom", defaultValue: "Using a custom separator color. Reset to follow the terminal theme.")
            ) {
                HStack(spacing: 8) {
                    ColorPicker(
                        "",
                        selection: Binding(
                            get: { Color(cmuxHex: paneDividerColor.current) ?? Color(nsColor: .separatorColor) },
                            set: { paneDividerColor.set($0.cmuxHexString) }
                        ),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                    .frame(width: 38)
                    .accessibilityIdentifier("SettingsPaneDividerColorPicker")
                    Button(String(localized: "settings.terminal.paneDividerColor.reset", defaultValue: "Default")) {
                        paneDividerColor.reset()
                    }
                    .controlSize(.small)
                    .disabled(paneDividerColor.current.isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private var resumeCommandsCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("terminal.resumeCommands"),
                String(localized: "settings.terminal.resumeCommands", defaultValue: "Resume Commands"),
                subtitle: String(
                    localized: "settings.terminal.resumeCommands.subtitle",
                    defaultValue: "Review signed command prefixes that can restore non-agent terminal surfaces."
                ),
                controlWidth: 170
            ) {
                HStack(spacing: 8) {
                    Text(verbatim: "0")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                    Button(String(localized: "settings.settingsJSON.openButton", defaultValue: "Open")) {
                        hostActions.openConfigInExternalEditor()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var mainCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(localized: "settings.terminal.tabBarFontSize", defaultValue: "Tab Bar Font Size"),
                subtitle: String(localized: "settings.terminal.tabBarFontSize.subtitle", defaultValue: "Controls the font size of the terminal and browser tab titles at the top of each pane."),
                controlWidth: 250
            ) {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 8) {
                        Slider(
                            value: Binding(get: { surfaceTabBarFont.points }, set: { surfaceTabBarFont.points = $0 }),
                            in: surfaceTabBarFont.minimum...surfaceTabBarFont.maximum,
                            step: 0.5
                        ) { editing in
                            if !editing { saveSurfaceTabBarFontSize(surfaceTabBarFont.points) }
                        }
                        .frame(width: 130)
                        .accessibilityIdentifier("SettingsTabBarFontSizeSlider")

                        Text(String.localizedStringWithFormat(String(localized: "settings.fontSize.valuePoints", defaultValue: "%@ pt"), hostActions.formattedFontSize(surfaceTabBarFont.points)))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)

                        Button(String(localized: "settings.terminal.tabBarFontSize.reset", defaultValue: "Reset")) {
                            surfaceTabBarFont.points = surfaceTabBarFont.defaultValue
                            saveSurfaceTabBarFontSize(surfaceTabBarFont.points)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(surfaceTabBarFont.isDefault)
                    }

                    if fontSaveFailed {
                        Text(String(localized: "settings.terminal.tabBarFontSize.saveFailed", defaultValue: "Couldn't save tab bar font size. Please try again."))
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.showScrollBar"),
                String(localized: "settings.terminal.scrollBar", defaultValue: "Show Terminal Scroll Bar"),
                subtitle: scrollBar.current
                    ? String(localized: "settings.terminal.scrollBar.subtitleOn", defaultValue: "Shows the right-edge terminal scroll bar in shell scrollback. cmux hides it automatically for alternate-screen style TUI surfaces.")
                    : String(localized: "settings.terminal.scrollBar.subtitleOff", defaultValue: "Hides the right-edge terminal scroll bar everywhere. Changes apply immediately and persist across relaunches.")
            ) {
                Toggle("", isOn: Binding(get: { scrollBar.current }, set: { scrollBar.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsTerminalScrollBarToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.copyOnSelect"),
                String(localized: "settings.terminal.copyOnSelect", defaultValue: "Copy on Selection"),
                subtitle: copyOnSelect.current
                    ? String(localized: "settings.terminal.copyOnSelect.subtitleOn", defaultValue: "Selected terminal text is copied to the system clipboard when the selection is committed.")
                    : String(localized: "settings.terminal.copyOnSelect.subtitleOff", defaultValue: "Terminal selections do not replace the system clipboard. Use Cmd+C to copy manually.")
            ) {
                Toggle("", isOn: Binding(get: { copyOnSelect.current }, set: { copyOnSelect.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsTerminalCopyOnSelectToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.autoResumeAgentSessions"),
                String(localized: "settings.terminal.agentAutoResume", defaultValue: "Resume Agent Sessions on Reopen"),
                subtitle: autoResume.current
                    ? String(localized: "settings.terminal.agentAutoResume.subtitleOn", defaultValue: "When cmux reopens after quit, restored agent terminals automatically run their resume command.")
                    : String(localized: "settings.terminal.agentAutoResume.subtitleOff", defaultValue: "When cmux reopens after quit, restored agent terminals stay idle until you resume them manually.")
            ) {
                Toggle("", isOn: Binding(get: { autoResume.current }, set: { autoResume.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsTerminalAgentAutoResumeToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.agentHibernation.enabled"),
                String(localized: "settings.terminal.agentHibernation", defaultValue: "Agent Hibernation"),
                subtitle: hibernation.current
                    ? String(localized: "settings.terminal.agentHibernation.subtitleOn", defaultValue: "Idle background agent terminals can be suspended when the live-terminal limit is exceeded.")
                    : String(localized: "settings.terminal.agentHibernation.subtitleOff", defaultValue: "Agent terminals stay live until you close them or quit cmux.")
            ) {
                Toggle("", isOn: Binding(get: { hibernation.current }, set: { hibernation.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsTerminalAgentHibernationToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.agentHibernation.idleSeconds"),
                String(localized: "settings.terminal.agentHibernation.idleSeconds", defaultValue: "Hibernate After Idle Seconds"),
                subtitle: String(localized: "settings.terminal.agentHibernation.idleSeconds.subtitle", defaultValue: "A terminal must have no output and report an idle agent lifecycle for this long before it can be suspended."),
                controlWidth: 140
            ) {
                Stepper(
                    "\(Int(idleSeconds.current))",
                    value: Binding(get: { idleSeconds.current }, set: { idleSeconds.set($0) }),
                    in: 5...604_800,
                    step: 60
                )
                .accessibilityIdentifier("SettingsTerminalAgentHibernationIdleSecondsStepper")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.agentHibernation.maxLiveTerminals"),
                String(localized: "settings.terminal.agentHibernation.maxLiveTerminals", defaultValue: "Max Live Agent Terminals"),
                subtitle: String(localized: "settings.terminal.agentHibernation.maxLiveTerminals.subtitle", defaultValue: "Visible terminals stay live. Extra idle background agent terminals hibernate oldest first."),
                controlWidth: 120
            ) {
                Stepper(
                    "\(maxLive.current)",
                    value: Binding(get: { maxLive.current }, set: { maxLive.set($0) }),
                    in: 1...256,
                    step: 1
                )
                .accessibilityIdentifier("SettingsTerminalAgentHibernationMaxLiveStepper")
            }
        }
    }

}

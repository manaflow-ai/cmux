import CmuxFoundation
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
    @State private var scrollSpeed: DefaultsValueModel<Double>
    @State private var activeScrollSpeedDragValue: Double?
    @State private var scrollBar: DefaultsValueModel<Bool>
    @State private var copyOnSelect: DefaultsValueModel<Bool>
    @State private var autoResume: DefaultsValueModel<Bool>
    @State private var hibernation: DefaultsValueModel<Bool>
    @State private var idleSeconds: DefaultsValueModel<Double>
    @State private var maxLive: DefaultsValueModel<Int>
    @State private var rendererReclaim: DefaultsValueModel<Bool>
    @State private var rendererIdleSeconds: DefaultsValueModel<Double>
    @State private var rendererMaxWarm: DefaultsValueModel<Int>
    @State private var memGuardrailEnabled: DefaultsValueModel<Bool>
    @State private var memGuardrailThresholdGB: DefaultsValueModel<Double>
    @State private var badgeEnabled: JSONValueModel<Bool>
    @State private var badgeTemplate: JSONValueModel<String>
    @State private var badgePosition: JSONValueModel<BadgePosition>
    @State private var badgeOpacity: JSONValueModel<Double>
    @State private var badgeColor: JSONValueModel<String>
    @State private var badgeFontSize: JSONValueModel<Double>

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        hostActions: SettingsHostActions,
        errorLog: SettingsErrorLog
    ) {
        self.jsonStore = jsonStore
        self.catalog = catalog
        self.hostActions = hostActions
        _badgeEnabled = State(initialValue: JSONValueModel(store: jsonStore, key: catalog.badge.enabled, errorLog: errorLog))
        _badgeTemplate = State(initialValue: JSONValueModel(store: jsonStore, key: catalog.badge.template, errorLog: errorLog))
        _badgePosition = State(initialValue: JSONValueModel(store: jsonStore, key: catalog.badge.position, errorLog: errorLog))
        _badgeOpacity = State(initialValue: JSONValueModel(store: jsonStore, key: catalog.badge.opacity, errorLog: errorLog))
        _badgeColor = State(initialValue: JSONValueModel(store: jsonStore, key: catalog.badge.color, errorLog: errorLog))
        _badgeFontSize = State(initialValue: JSONValueModel(store: jsonStore, key: catalog.badge.fontSize, errorLog: errorLog))
        _surfaceTabBarFont = State(initialValue: hostActions.surfaceTabBarFontSize())
        _scrollSpeed = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.scrollSpeed))
        _scrollBar = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.showScrollBar))
        _copyOnSelect = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.copyOnSelect))
        _autoResume = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.autoResumeAgentSessions))
        _hibernation = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.agentHibernationEnabled))
        _idleSeconds = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.agentHibernationIdleSeconds))
        _maxLive = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.agentHibernationMaxLiveTerminals))
        _rendererReclaim = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.rendererRealizationEnabled))
        _rendererIdleSeconds = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.rendererRealizationIdleSeconds))
        _rendererMaxWarm = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.rendererRealizationMaxWarmRenderers))
        _memGuardrailEnabled = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.runawayMemoryGuardrailEnabled))
        _memGuardrailThresholdGB = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.runawayMemoryGuardrailThresholdGB))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.terminal", defaultValue: "Terminal"), section: .terminal)
            mainCard
            badgeCard
            resumeCommandsCard
        }
        .task { startObservingSettings() }
    }

    private func startObservingSettings() {
        let models: [any SettingObservationStarting] = [
            scrollSpeed,
            scrollBar,
            copyOnSelect,
            autoResume,
            hibernation,
            idleSeconds,
            maxLive,
            rendererReclaim,
            rendererIdleSeconds,
            rendererMaxWarm,
            memGuardrailEnabled,
            memGuardrailThresholdGB,
            badgeEnabled,
            badgeTemplate,
            badgePosition,
            badgeOpacity,
            badgeColor,
            badgeFontSize,
        ]
        models.forEach { $0.startObserving() }
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

    private var displayedScrollSpeed: Double {
        activeScrollSpeedDragValue ?? scrollSpeed.current
    }

    private func commitScrollSpeedDrag() {
        scrollSpeed.set(displayedScrollSpeed)
        activeScrollSpeedDragValue = nil
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
                        .cmuxFont(.caption, monospacedDigit: true)
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

    /// Localized display name for a badge anchor position.
    private func badgePositionLabel(_ position: BadgePosition) -> String {
        switch position {
        case .topLeading:
            return String(localized: "badge.position.topLeading", defaultValue: "Top Left")
        case .topTrailing:
            return String(localized: "badge.position.topTrailing", defaultValue: "Top Right")
        case .bottomLeading:
            return String(localized: "badge.position.bottomLeading", defaultValue: "Bottom Left")
        case .bottomTrailing:
            return String(localized: "badge.position.bottomTrailing", defaultValue: "Bottom Right")
        case .center:
            return String(localized: "badge.position.center", defaultValue: "Center")
        }
    }

    /// The color shown in the badge color well, resolving the stored
    /// `badge.color` string (a SwiftUI color name or `#RRGGBB` hex) via
    /// ``BadgeColor``. Falls back to the terminal label color (`.primary`) when
    /// the value is empty or unparseable, so the well still shows something the
    /// user can click to pick a concrete color.
    private func badgeColorWellColor() -> Color {
        guard let parsed = BadgeColor(parsing: badgeColor.current) else {
            return .primary
        }
        return Color(red: parsed.red, green: parsed.green, blue: parsed.blue)
    }

    @ViewBuilder
    private var badgeCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("badge.enabled"),
                String(localized: "settings.terminal.badge", defaultValue: "Terminal Badge"),
                subtitle: badgeEnabled.current
                    ? String(localized: "settings.terminal.badge.subtitleOn", defaultValue: "A scroll-fixed watermark identifying each terminal's workspace and tab, shown inside every surface.")
                    : String(localized: "settings.terminal.badge.subtitleOff", defaultValue: "No identity watermark is drawn inside terminal surfaces.")
            ) {
                Toggle("", isOn: Binding(get: { badgeEnabled.current }, set: { badgeEnabled.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsTerminalBadgeToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("badge.template"),
                String(localized: "settings.terminal.badge.template", defaultValue: "Badge Text"),
                subtitle: String(localized: "settings.terminal.badge.template.subtitle", defaultValue: "Free-form text. Use {workspace}, {tab}, {tabIndex}, and {workspaceIndex} placeholders; other text is shown as-is."),
                controlWidth: 330
            ) {
                TextField("", text: Binding(get: { badgeTemplate.current }, set: { badgeTemplate.set($0) }))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!badgeEnabled.current)
                    .accessibilityIdentifier("SettingsTerminalBadgeTemplateField")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("badge.position"),
                String(localized: "settings.terminal.badge.position", defaultValue: "Badge Position"),
                subtitle: String(localized: "settings.terminal.badge.position.subtitle", defaultValue: "Which corner (or center) of the terminal surface the badge anchors to."),
                controlWidth: 160
            ) {
                Picker("", selection: Binding(get: { badgePosition.current }, set: { badgePosition.set($0) })) {
                    ForEach(BadgePosition.allCases, id: \.self) { position in
                        Text(badgePositionLabel(position)).tag(position)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(!badgeEnabled.current)
                .accessibilityIdentifier("SettingsTerminalBadgePositionPicker")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("badge.opacity"),
                String(localized: "settings.terminal.badge.opacity", defaultValue: "Badge Opacity"),
                subtitle: String(localized: "settings.terminal.badge.opacity.subtitle", defaultValue: "How visible the badge is, from faint (0%) to fully opaque (100%)."),
                controlWidth: 250
            ) {
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(get: { badgeOpacity.current }, set: { badgeOpacity.set($0) }),
                        in: 0...1,
                        step: 0.01
                    )
                    .frame(width: 130)
                    .disabled(!badgeEnabled.current)
                    .accessibilityIdentifier("SettingsTerminalBadgeOpacitySlider")

                    Text(String.localizedStringWithFormat(String(localized: "settings.terminal.badge.opacity.value", defaultValue: "%d%%"), Int((badgeOpacity.current * 100).rounded())))
                        .cmuxFont(size: 12, weight: .medium, design: .rounded)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("badge.fontSize"),
                String(localized: "settings.terminal.badge.fontSize", defaultValue: "Badge Font Size"),
                subtitle: String(localized: "settings.terminal.badge.fontSize.subtitle", defaultValue: "Point size of the badge text."),
                controlWidth: 250
            ) {
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(get: { badgeFontSize.current }, set: { badgeFontSize.set($0) }),
                        in: BadgeCatalogSection.fontSizeMinimum...BadgeCatalogSection.fontSizeMaximum,
                        step: 1
                    )
                    .frame(width: 130)
                    .disabled(!badgeEnabled.current)
                    .accessibilityIdentifier("SettingsTerminalBadgeFontSizeSlider")

                    Text(String.localizedStringWithFormat(String(localized: "settings.fontSize.valuePoints", defaultValue: "%@ pt"), hostActions.formattedFontSize(badgeFontSize.current)))
                        .cmuxFont(size: 12, weight: .medium, design: .rounded)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("badge.color"),
                String(localized: "settings.terminal.badge.color", defaultValue: "Badge Color"),
                subtitle: String(localized: "settings.terminal.badge.color.subtitle", defaultValue: "A color name (red, blue, green, …) or #RRGGBB hex. Leave empty to follow the terminal's text color."),
                controlWidth: 200
            ) {
                HStack(spacing: 8) {
                    ColorPicker("", selection: Binding(
                        get: { badgeColorWellColor() },
                        set: { newColor in badgeColor.set(newColor.cmuxHexString) }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 38)
                    .disabled(!badgeEnabled.current)
                    .accessibilityIdentifier("SettingsTerminalBadgeColorWell")

                    TextField(
                        String(localized: "settings.terminal.badge.color.placeholder", defaultValue: "name or #RRGGBB"),
                        text: Binding(get: { badgeColor.current }, set: { badgeColor.set($0) })
                    )
                    .textFieldStyle(.roundedBorder)
                    .disabled(!badgeEnabled.current)
                    .accessibilityIdentifier("SettingsTerminalBadgeColorField")
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
                            .cmuxFont(size: 12, weight: .medium, design: .rounded)
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
                            .cmuxFont(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.scrollSpeed"),
                String(localized: "settings.terminal.scrollSpeed", defaultValue: "Scroll Speed"),
                subtitle: String(localized: "settings.terminal.scrollSpeed.subtitle", defaultValue: "Multiplier applied to terminal scroll wheel and trackpad deltas. Higher scrolls faster."),
                controlWidth: 250
            ) {
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(get: { displayedScrollSpeed }, set: { activeScrollSpeedDragValue = $0 }),
                        in: TerminalCatalogSection.scrollSpeedMinimum...TerminalCatalogSection.scrollSpeedMaximum,
                        step: 0.05
                    ) { editing in
                        if !editing { commitScrollSpeedDrag() }
                    }
                    .frame(width: 130)
                    .accessibilityIdentifier("SettingsTerminalScrollSpeedSlider")

                    Text(String.localizedStringWithFormat(String(localized: "settings.terminal.scrollSpeed.value", defaultValue: "%.2f×"), displayedScrollSpeed))
                        .cmuxFont(size: 12, weight: .medium, design: .rounded)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)

                    Button(String(localized: "settings.terminal.scrollSpeed.reset", defaultValue: "Reset")) {
                        activeScrollSpeedDragValue = nil
                        scrollSpeed.set(TerminalCatalogSection.scrollSpeedDefault)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(abs(displayedScrollSpeed - TerminalCatalogSection.scrollSpeedDefault) < 0.001)
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
                    ? String(localized: "settings.terminal.copyOnSelect.subtitleOn", defaultValue: "Selected terminal text is also copied to the system clipboard when the selection is committed.")
                    : String(localized: "settings.terminal.copyOnSelect.subtitleOff", defaultValue: "cmux does not add system-clipboard copy on selection. Ghostty config still controls Paste Selection.")
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
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.rendererRealization.enabled"),
                String(localized: "settings.terminal.rendererRealization", defaultValue: "Reclaim Offscreen Terminal Memory"),
                subtitle: rendererReclaim.current
                    ? String(localized: "settings.terminal.rendererRealization.subtitleOn", defaultValue: "Off-screen terminals release their GPU renderer memory while idle and rebuild it instantly when you switch back. The process keeps running.")
                    : String(localized: "settings.terminal.rendererRealization.subtitleOff", defaultValue: "Every visited terminal keeps its full GPU renderer allocated until you close it, even when off-screen.")
            ) {
                Toggle("", isOn: Binding(get: { rendererReclaim.current }, set: { rendererReclaim.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsTerminalRendererRealizationToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.rendererRealization.idleSeconds"),
                String(localized: "settings.terminal.rendererRealization.idleSeconds", defaultValue: "Reclaim After Idle Seconds"),
                subtitle: String(localized: "settings.terminal.rendererRealization.idleSeconds.subtitle", defaultValue: "An off-screen terminal must stay off-screen this long before its renderer memory is reclaimed."),
                controlWidth: 140
            ) {
                Stepper(
                    "\(Int(rendererIdleSeconds.current))",
                    value: Binding(get: { rendererIdleSeconds.current }, set: { rendererIdleSeconds.set($0) }),
                    in: 5...604_800,
                    step: 10
                )
                .accessibilityIdentifier("SettingsTerminalRendererRealizationIdleSecondsStepper")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.rendererRealization.maxWarmRenderers"),
                String(localized: "settings.terminal.rendererRealization.maxWarmRenderers", defaultValue: "Max Warm Renderers"),
                subtitle: String(localized: "settings.terminal.rendererRealization.maxWarmRenderers.subtitle", defaultValue: "The most recently visible terminals keep their renderer ready so switching stays instant. Extra off-screen renderers are reclaimed oldest first."),
                controlWidth: 120
            ) {
                Stepper(
                    "\(rendererMaxWarm.current)",
                    value: Binding(get: { rendererMaxWarm.current }, set: { rendererMaxWarm.set($0) }),
                    in: 1...256,
                    step: 1
                )
                .accessibilityIdentifier("SettingsTerminalRendererRealizationMaxWarmStepper")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:terminal:memory-guardrail",
                String(localized: "settings.terminal.memoryGuardrail", defaultValue: "Runaway Memory Guardrail"),
                subtitle: memGuardrailEnabled.current
                    ? String(localized: "settings.terminal.memoryGuardrail.subtitleOn", defaultValue: "cmux warns you with a badge and a banner when one pane's process tree uses too much memory, so a single leak can't crash the whole app.")
                    : String(localized: "settings.terminal.memoryGuardrail.subtitleOff", defaultValue: "No warning is shown when a pane's process tree grows large. A leaking process can OOM-suspend the entire app.")
            ) {
                Toggle("", isOn: Binding(get: { memGuardrailEnabled.current }, set: { memGuardrailEnabled.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsTerminalMemoryGuardrailToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:terminal:memory-guardrail-threshold",
                String(localized: "settings.terminal.memoryGuardrail.threshold", defaultValue: "Memory Warning Threshold (GB)"),
                subtitle: String(localized: "settings.terminal.memoryGuardrail.threshold.subtitle", defaultValue: "A pane is flagged once its combined process-tree memory crosses this many gigabytes."),
                controlWidth: 120
            ) {
                Stepper(
                    "\(Int(memGuardrailThresholdGB.current))",
                    value: Binding(get: { memGuardrailThresholdGB.current }, set: { memGuardrailThresholdGB.set($0) }),
                    in: 1...256,
                    step: 1
                )
                .disabled(!memGuardrailEnabled.current)
                .accessibilityIdentifier("SettingsTerminalMemoryGuardrailThresholdStepper")
            }
        }
    }

}

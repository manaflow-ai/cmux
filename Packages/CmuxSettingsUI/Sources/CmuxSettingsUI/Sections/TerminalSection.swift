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
    @State private var quickTerminalPosition: DefaultsValueModel<String>
    @State private var quickTerminalPrimarySizeRatio: DefaultsValueModel<Double>
    @State private var quickTerminalSecondarySizeRatio: DefaultsValueModel<Double>
    @State private var quickTerminalAutoHide: DefaultsValueModel<Bool>
    @State private var autoResume: DefaultsValueModel<Bool>
    @State private var hibernation: DefaultsValueModel<Bool>
    @State private var idleSeconds: DefaultsValueModel<Double>
    @State private var maxLive: DefaultsValueModel<Int>
    @State private var rendererReclaim: DefaultsValueModel<Bool>
    @State private var rendererIdleSeconds: DefaultsValueModel<Double>
    @State private var rendererMaxWarm: DefaultsValueModel<Int>

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        hostActions: SettingsHostActions
    ) {
        self.jsonStore = jsonStore
        self.catalog = catalog
        self.hostActions = hostActions
        _surfaceTabBarFont = State(initialValue: hostActions.surfaceTabBarFontSize())
        _scrollBar = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.showScrollBar))
        _copyOnSelect = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.copyOnSelect))
        _quickTerminalPosition = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.quickTerminalPosition))
        _quickTerminalPrimarySizeRatio = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.quickTerminalPrimarySizeRatio))
        _quickTerminalSecondarySizeRatio = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.quickTerminalSecondarySizeRatio))
        _quickTerminalAutoHide = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.quickTerminalAutoHide))
        _autoResume = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.autoResumeAgentSessions))
        _hibernation = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.agentHibernationEnabled))
        _idleSeconds = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.agentHibernationIdleSeconds))
        _maxLive = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.agentHibernationMaxLiveTerminals))
        _rendererReclaim = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.rendererRealizationEnabled))
        _rendererIdleSeconds = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.rendererRealizationIdleSeconds))
        _rendererMaxWarm = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.rendererRealizationMaxWarmRenderers))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.terminal", defaultValue: "Terminal"), section: .terminal)
            mainCard
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

    private var quickTerminalPositionBinding: Binding<String> {
        Binding(
            get: {
                QuickTerminalPositionOption(rawValue: quickTerminalPosition.current)?.rawValue
                    ?? QuickTerminalPositionOption.top.rawValue
            },
            set: { newValue in
                quickTerminalPosition.set(
                    QuickTerminalPositionOption(rawValue: newValue)?.rawValue
                        ?? QuickTerminalPositionOption.top.rawValue
                )
            }
        )
    }

    private func quickTerminalRatioBinding(_ model: DefaultsValueModel<Double>) -> Binding<Double> {
        Binding(
            get: { clampedQuickTerminalRatio(model.current) },
            set: { model.set(clampedQuickTerminalRatio($0)) }
        )
    }

    private func clampedQuickTerminalRatio(_ value: Double) -> Double {
        min(max(value, 0.2), 1.0)
    }

    private func quickTerminalRatioPercentLabel(_ ratio: Double) -> String {
        "\(Int((clampedQuickTerminalRatio(ratio) * 100).rounded()))%"
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
                configurationReview: .json("terminal.quickTerminalPosition"),
                String(localized: "settings.quickTerminal.position", defaultValue: "Quick Terminal Position"),
                subtitle: String(localized: "settings.quickTerminal.position.subtitle", defaultValue: "Choose where the quick terminal slides in."),
                controlWidth: 196
            ) {
                Picker("", selection: quickTerminalPositionBinding) {
                    ForEach(QuickTerminalPositionOption.allCases) { option in
                        Text(verbatim: option.localizedName)
                            .tag(option.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("SettingsQuickTerminalPositionPicker")
                .accessibilityLabel(
                    String(localized: "settings.quickTerminal.position", defaultValue: "Quick Terminal Position")
                )
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.quickTerminalPrimarySizeRatio"),
                String(localized: "settings.quickTerminal.primarySize", defaultValue: "Quick Terminal Primary Size"),
                subtitle: String(localized: "settings.quickTerminal.primarySize.subtitle", defaultValue: "Size along the slide-in axis."),
                controlWidth: 196
            ) {
                HStack(spacing: 8) {
                    Slider(
                        value: quickTerminalRatioBinding(quickTerminalPrimarySizeRatio),
                        in: 0.2...1.0
                    )
                    .frame(width: 132)

                    Text(verbatim: quickTerminalRatioPercentLabel(quickTerminalPrimarySizeRatio.current))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                .accessibilityIdentifier("SettingsQuickTerminalPrimarySizeSlider")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.quickTerminalSecondarySizeRatio"),
                String(localized: "settings.quickTerminal.secondarySize", defaultValue: "Quick Terminal Secondary Size"),
                subtitle: String(localized: "settings.quickTerminal.secondarySize.subtitle", defaultValue: "Size across the opposite axis."),
                controlWidth: 196
            ) {
                HStack(spacing: 8) {
                    Slider(
                        value: quickTerminalRatioBinding(quickTerminalSecondarySizeRatio),
                        in: 0.2...1.0
                    )
                    .frame(width: 132)

                    Text(verbatim: quickTerminalRatioPercentLabel(quickTerminalSecondarySizeRatio.current))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                .accessibilityIdentifier("SettingsQuickTerminalSecondarySizeSlider")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.quickTerminalAutoHide"),
                String(localized: "settings.quickTerminal.autoHide", defaultValue: "Quick Terminal Auto-Hide"),
                subtitle: quickTerminalAutoHide.current
                    ? String(localized: "settings.quickTerminal.autoHide.subtitleOn", defaultValue: "Hide automatically when it loses focus.")
                    : String(localized: "settings.quickTerminal.autoHide.subtitleOff", defaultValue: "Keep visible when focus moves away.")
            ) {
                Toggle("", isOn: Binding(get: { quickTerminalAutoHide.current }, set: { quickTerminalAutoHide.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsQuickTerminalAutoHideToggle")
                    .accessibilityLabel(
                        String(localized: "settings.quickTerminal.autoHide", defaultValue: "Quick Terminal Auto-Hide")
                    )
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
        }
    }

}

private enum QuickTerminalPositionOption: String, CaseIterable, Identifiable {
    case top
    case bottom
    case left
    case right
    case center

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .top:
            return String(localized: "settings.quickTerminal.position.top", defaultValue: "Top")
        case .bottom:
            return String(localized: "settings.quickTerminal.position.bottom", defaultValue: "Bottom")
        case .left:
            return String(localized: "settings.quickTerminal.position.left", defaultValue: "Left")
        case .right:
            return String(localized: "settings.quickTerminal.position.right", defaultValue: "Right")
        case .center:
            return String(localized: "settings.quickTerminal.position.center", defaultValue: "Center")
        }
    }
}

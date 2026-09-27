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
    private let sessionContentWidthSettings = SessionContentWidthSettings()

    @State private var surfaceTabBarFont: SettingsFontSize
    @State private var fontSaveFailed = false
    @State private var tasks = MainActorTaskStore<String>()
    @State private var scrollSpeed: DefaultsValueModel<Double>
    @State private var activeScrollSpeedDragValue: Double?
    @State private var sessionContentMaxWidth: DefaultsValueModel<Double>
    @State private var rememberedSessionContentMaxWidth: DefaultsValueModel<Double>
    @State private var sessionContentAlignment: DefaultsValueModel<SessionContentAlignment>
    @State private var scrollBar: DefaultsValueModel<Bool>
    @State private var copyOnSelect: DefaultsValueModel<Bool>
    @State private var reflowHardWrapOnCopy: DefaultsValueModel<Bool>
    @State private var confirmUnsafePaste: DefaultsValueModel<Bool>
    @State private var textEditingGestures: DefaultsValueModel<Bool>
    @State private var passwordInputIndicator: DefaultsValueModel<Bool>
    @State private var passwordInputDots: DefaultsValueModel<Bool>
    @State private var adaptiveDefaultTheme: DefaultsValueModel<Bool>
    @State private var autoResume: DefaultsValueModel<Bool>
    @State private var hibernation: DefaultsValueModel<Bool>
    @State private var idleSeconds: DefaultsValueModel<Double>
    @State private var maxLive: DefaultsValueModel<Int>
    @State private var rendererReclaim: DefaultsValueModel<Bool>
    @State private var rendererIdleSeconds: DefaultsValueModel<Double>
    @State private var rendererMaxWarm: DefaultsValueModel<Int>
    @State private var memGuardrailEnabled: DefaultsValueModel<Bool>
    @State private var memGuardrailThresholdGB: DefaultsValueModel<Double>

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
        _scrollSpeed = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.scrollSpeed))
        _sessionContentMaxWidth = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.sessionContentMaxWidth))
        _rememberedSessionContentMaxWidth = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.rememberedSessionContentMaxWidth))
        _sessionContentAlignment = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.sessionContentAlignment))
        _scrollBar = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.showScrollBar))
        _copyOnSelect = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.copyOnSelect))
        _reflowHardWrapOnCopy = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.reflowHardWrapOnCopy))
        _confirmUnsafePaste = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.confirmUnsafePaste))
        _textEditingGestures = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.textEditingGestures))
        _passwordInputIndicator = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.showPasswordInputIndicator))
        _passwordInputDots = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.showPasswordInputDots))
        _adaptiveDefaultTheme = State(
            initialValue: DefaultsValueModel(
                store: defaultsStore,
                key: catalog.terminal.adaptiveDefaultTheme
            )
        )
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
            TerminalGhosttyOptionsCard(hostActions: hostActions)
            LocalTmuxSettingsCard(hostActions: hostActions)
            resumeCommandsCard
        }
        .task { startObservingSettings() }
    }

    private func startObservingSettings() {
        let models: [any SettingObservationStarting] = [
            scrollSpeed,
            sessionContentMaxWidth,
            rememberedSessionContentMaxWidth,
            sessionContentAlignment,
            scrollBar,
            copyOnSelect,
            reflowHardWrapOnCopy,
            confirmUnsafePaste,
            textEditingGestures,
            passwordInputIndicator,
            passwordInputDots,
            adaptiveDefaultTheme,
            autoResume,
            hibernation,
            idleSeconds,
            maxLive,
            rendererReclaim,
            rendererIdleSeconds,
            rendererMaxWarm,
            memGuardrailEnabled,
            memGuardrailThresholdGB,
        ]
        models.forEach { $0.startObserving() }
    }

    /// Persists a new tab-bar font size, cancelling any in-flight save so a
    /// rapid sequence of slider releases only reflects the latest value (the
    /// host serializes the underlying writes; this keeps the UI state in step).
    private func saveSurfaceTabBarFontSize(_ points: Double) {
        tasks.replaceOnMainActor("fontSave") {
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

    private var sessionContentWidthEnabled: Bool {
        sessionContentWidthSettings.configuredMaximumWidth(from: sessionContentMaxWidth.current) != nil
    }

    private var sessionContentWidthToggleBinding: Binding<Bool> {
        Binding(
            get: { sessionContentWidthEnabled },
            set: { enabled in
                if enabled {
                    let width = sessionContentWidthSettings.editorMaximumWidth(
                        activeStoredValue: sessionContentMaxWidth.current,
                        rememberedStoredValue: rememberedSessionContentMaxWidth.current
                    )
                    rememberedSessionContentMaxWidth.set(width)
                    sessionContentMaxWidth.set(width)
                } else {
                    if let activeWidth = sessionContentWidthSettings.configuredMaximumWidth(
                        from: sessionContentMaxWidth.current
                    ) {
                        rememberedSessionContentMaxWidth.set(activeWidth)
                    }
                    sessionContentMaxWidth.set(SessionContentWidthSettings.noMaximumWidth)
                }
            }
        )
    }

    private var sessionContentWidthEditorBinding: Binding<Double> {
        Binding(
            get: {
                sessionContentWidthSettings.editorMaximumWidth(
                    activeStoredValue: sessionContentMaxWidth.current,
                    rememberedStoredValue: rememberedSessionContentMaxWidth.current
                )
            },
            set: { requestedWidth in
                let width = sessionContentWidthSettings.clampedMaximumWidth(requestedWidth)
                rememberedSessionContentMaxWidth.set(width)
                if sessionContentWidthEnabled {
                    sessionContentMaxWidth.set(width)
                }
            }
        )
    }

    private var sessionContentWidthSubtitle: String {
        String(
            localized: "settings.terminal.sessionContentWidth.subtitle",
            defaultValue: "Wraps terminal and agent chat content at this width. Narrow panes still use their full width."
        )
    }

    private func sessionContentAlignmentTitle(_ alignment: SessionContentAlignment) -> String {
        switch alignment {
        case .left:
            return String(localized: "settings.terminal.sessionContentAlignment.left", defaultValue: "Left")
        case .center:
            return String(localized: "settings.terminal.sessionContentAlignment.center", defaultValue: "Center")
        case .right:
            return String(localized: "settings.terminal.sessionContentAlignment.right", defaultValue: "Right")
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
                configurationReview: .settingsOnly,
                String(localized: "settings.app.theme", defaultValue: "Theme")
            ) {
                Button(
                    String(localized: "settings.browser.import.choose", defaultValue: "Choose…")
                ) {
                    hostActions.openTerminalThemePicker()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("SettingsTerminalThemePickerButton")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(localized: "settings.terminal.importFromTerminal", defaultValue: "Import from Another Terminal"),
                subtitle: String(
                    localized: "settings.terminal.importFromTerminal.subtitle",
                    defaultValue: "Bring over your font, colors, cursor and more from iTerm2, Terminal, Alacritty, Kitty, WezTerm or Warp."
                )
            ) {
                Button(
                    String(localized: "settings.terminal.importFromTerminal.button", defaultValue: "Import…")
                ) {
                    hostActions.openTerminalImport()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("SettingsTerminalImportButton")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.adaptiveDefaultTheme"),
                String(
                    localized: "settings.terminal.adaptiveDefaultTheme",
                    defaultValue: "Adapt Default Theme to Appearance"
                ),
                subtitle: String(localized: "settings.terminal.adaptiveDefaultTheme.subtitle", defaultValue: "Matches terminal colors to the light or dark appearance when no Ghostty theme or colors are set.")
            ) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { adaptiveDefaultTheme.current },
                        set: { enabled in
                            adaptiveDefaultTheme.set(enabled) {
                                @MainActor [hostActions] in
                                hostActions.terminalAdaptiveDefaultThemeDidChange()
                            }
                        }
                    )
                )
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier(
                    "SettingsTerminalAdaptiveDefaultThemeToggle"
                )
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.sessionContentMaxWidth"),
                String(localized: "settings.terminal.sessionContentWidth", defaultValue: "Session Content Width"),
                subtitle: sessionContentWidthSubtitle,
                controlWidth: 250
            ) {
                HStack(spacing: 8) {
                    Toggle("", isOn: sessionContentWidthToggleBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityIdentifier("SettingsSessionContentWidthToggle")
                        .accessibilityLabel(
                            String(
                                localized: "settings.terminal.sessionContentWidth.toggle",
                                defaultValue: "Limit session content width"
                            )
                        )

                    TextField("", value: sessionContentWidthEditorBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                        .disabled(!sessionContentWidthEnabled)
                        .accessibilityIdentifier("SettingsSessionContentWidthField")
                        .accessibilityLabel(
                            String(localized: "settings.terminal.sessionContentWidth", defaultValue: "Session Content Width")
                        )

                    Text(String(localized: "settings.terminal.sessionContentWidth.unit", defaultValue: "pt"))
                        .foregroundStyle(.secondary)
                }
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.sessionContentAlignment"),
                String(localized: "settings.terminal.sessionContentAlignment", defaultValue: "Session Content Alignment"),
                subtitle: String(
                    localized: "settings.terminal.sessionContentAlignment.subtitle",
                    defaultValue: "Places width-capped content within the pane."
                ),
                controlWidth: 250
            ) {
                Picker(
                    "",
                    selection: Binding(
                        get: { sessionContentAlignment.current },
                        set: { sessionContentAlignment.set($0) }
                    )
                ) {
                    ForEach(SessionContentAlignment.allCases, id: \.self) { alignment in
                        Text(sessionContentAlignmentTitle(alignment)).tag(alignment)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
                .disabled(!sessionContentWidthEnabled)
                .accessibilityIdentifier("SettingsSessionContentAlignmentPicker")
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
                subtitle: String(localized: "settings.terminal.scrollBar.subtitle", defaultValue: "Shows a scroll bar in terminals, except in full-screen apps.")
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
                subtitle: String(localized: "settings.terminal.copyOnSelect.subtitle", defaultValue: "Selecting text in a terminal copies it to the clipboard.")
            ) {
                Toggle("", isOn: Binding(get: { copyOnSelect.current }, set: { copyOnSelect.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsTerminalCopyOnSelectToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.reflowHardWrapOnCopy"),
                String(localized: "settings.terminal.reflowHardWrapOnCopy", defaultValue: "Reflow Hard-Wrapped Text on Copy"),
                subtitle: String(localized: "settings.terminal.reflowHardWrapOnCopy.subtitle", defaultValue: "Copying text also joins line breaks a program printed at the full terminal width and drops a short continuation indent. Soft-wrapped lines always copy as one line.")
            ) {
                Toggle("", isOn: Binding(get: { reflowHardWrapOnCopy.current }, set: { reflowHardWrapOnCopy.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsTerminalReflowHardWrapOnCopyToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.confirmUnsafePaste"),
                String(localized: "settings.terminal.confirmUnsafePaste", defaultValue: "Confirm Unsafe Pastes"),
                subtitle: confirmUnsafePaste.current
                    ? String(localized: "settings.terminal.confirmUnsafePaste.subtitleOn", defaultValue: "A paste Ghostty flags as unsafe, such as several lines into a program without bracketed paste, waits for you to confirm it in a sheet on the window.")
                    : String(localized: "settings.terminal.confirmUnsafePaste.subtitleOff", defaultValue: "Pastes Ghostty flags as unsafe go through without asking.")
            ) {
                Toggle("", isOn: Binding(get: { confirmUnsafePaste.current }, set: { confirmUnsafePaste.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsTerminalConfirmUnsafePasteToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.textEditingGestures"),
                String(localized: "settings.terminal.textEditingGestures", defaultValue: "Text Editing Gestures"),
                subtitle: String(localized: "settings.terminal.textEditingGestures.subtitle", defaultValue: "Pressing Command or Option with an arrow key or Delete moves or deletes by line or word. Full-screen terminal apps receive the rewritten keys too, so turn this off for apps that need the original keys.")
            ) {
                Toggle("", isOn: Binding(get: { textEditingGestures.current }, set: { textEditingGestures.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsTerminalTextEditingGesturesToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.showPasswordInputIndicator"),
                String(localized: "settings.terminal.showPasswordInputIndicator", defaultValue: "Password Input Indicator"),
                subtitle: String(localized: "settings.terminal.showPasswordInputIndicator.subtitle", defaultValue: "Shows a lock badge in the terminal corner while a program such as sudo or ssh reads a password with echo off.")
            ) {
                Toggle("", isOn: Binding(get: { passwordInputIndicator.current }, set: { passwordInputIndicator.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsTerminalPasswordInputIndicatorToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.showPasswordInputDots"),
                String(localized: "settings.terminal.showPasswordInputDots", defaultValue: "Show Typed Password Dots"),
                subtitle: String(localized: "settings.terminal.showPasswordInputDots.subtitle", defaultValue: "Shows one dot in the badge per typed character. cmux keeps only a count, never the characters.")
            ) {
                Toggle("", isOn: Binding(get: { passwordInputDots.current }, set: { passwordInputDots.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(!passwordInputIndicator.current)
                    .accessibilityIdentifier("SettingsTerminalPasswordInputDotsToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.autoResumeAgentSessions"),
                String(localized: "settings.terminal.agentAutoResume", defaultValue: "Resume Agent Sessions on Reopen"),
                subtitle: String(localized: "settings.terminal.agentAutoResume.subtitle", defaultValue: "Reopening cmux resumes agent sessions automatically.")
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
                subtitle: String(localized: "settings.terminal.agentHibernation.subtitle", defaultValue: "Hibernates idle background agent terminals above the live terminal limit. Even when this is off, cmux may hibernate them under critical memory pressure.")
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
                subtitle: String(localized: "settings.terminal.rendererRealization.subtitle", defaultValue: "Frees graphics memory from terminals that are out of view. Their processes keep running.")
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
                subtitle: String(localized: "settings.terminal.memoryGuardrail.subtitle", defaultValue: "Warns when the processes in one pane use too much memory.")
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

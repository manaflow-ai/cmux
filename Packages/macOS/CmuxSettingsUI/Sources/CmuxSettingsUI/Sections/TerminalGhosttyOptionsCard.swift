import CmuxFoundation
import SwiftUI

/// Native rows for the Ghostty options people change most: font, cursor,
/// padding, background, Option as Alt, and scrollback.
///
/// Each row shows the value in effect, folded from the user's own Ghostty
/// config and cmux's config, and writes a single key to cmux's config, which
/// Ghostty loads last. The row's caption is that key, so the same option can
/// be found in a config file.
@MainActor
struct TerminalGhosttyOptionsCard: View {
    let hostActions: SettingsHostActions

    @State private var options = GhosttyTerminalOptions.defaults
    @State private var hasLoaded = false
    @State private var monospacedFamilies: [String] = []
    @State private var activeOpacityDragValue: Double?
    @State private var saveFailed = false
    /// Changes shown optimistically whose write hasn't finished yet, reapplied
    /// over each re-read so one row's refresh doesn't undo another row's edit.
    @State private var pendingChanges: [GhosttyTerminalOptionKey: GhosttyTerminalOptionChange] = [:]
    /// Keys whose written value a later-loading config file overrides, with
    /// that file's display path.
    @State private var overriddenKeys: [GhosttyTerminalOptionKey: String] = [:]
    @State private var tasks = MainActorTaskStore<GhosttyTerminalOptionKey>()

    private static let bytesPerMegabyte = 1_000_000
    /// Coalesces stepper autorepeat and quick clicks into one write and reload.
    private static let writeDelay: Duration = .milliseconds(250)

    var body: some View {
        SettingsCard {
            SettingsCardNote(String(
                localized: "settings.terminal.ghostty.note",
                defaultValue: "These rows show the value in effect and save to cmux's Ghostty config, which loads after your own Ghostty config. The caption under each row is its config key."
            ))
            if saveFailed {
                Text(String(
                    localized: "settings.terminal.ghostty.saveFailed",
                    defaultValue: "Couldn't save the Ghostty config. Please try again."
                ))
                .cmuxFont(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsCardDivider()
            fontRows
            SettingsCardDivider()
            cursorRows
            SettingsCardDivider()
            windowRows
            SettingsCardDivider()
            inputRows
        }
        .disabled(!hasLoaded)
        .task { await load() }
    }

    // MARK: Rows

    @ViewBuilder
    private var fontRows: some View {
        optionRow(
            "font-family",
            String(localized: "settings.terminal.ghostty.fontFamily", defaultValue: "Font"),
            key: .fontFamily,
            controlWidth: 220
        ) {
            Picker("", selection: Binding(
                get: { options.fontFamily ?? "" },
                set: { apply(.fontFamilies(options.fontFamiliesChoosing($0))) }
            )) {
                Text(String(localized: "settings.terminal.ghostty.fontFamily.default", defaultValue: "Default")).tag("")
                Divider()
                ForEach(fontFamilyChoices, id: \.self) { family in
                    Text(verbatim: family).tag(family)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier("SettingsTerminalGhosttyFontFamilyPicker")
        }
        SettingsCardDivider()
        optionRow(
            "font-size",
            String(localized: "settings.terminal.ghostty.fontSize", defaultValue: "Font Size"),
            key: .fontSize,
            controlWidth: 140
        ) {
            Stepper(
                value: Binding(get: { options.fontSize }, set: { apply(.fontSize($0)) }),
                in: 4...96,
                step: 0.5
            ) {
                Text(String.localizedStringWithFormat(
                    String(localized: "settings.fontSize.valuePoints", defaultValue: "%@ pt"),
                    hostActions.formattedFontSize(options.fontSize)
                ))
                .monospacedDigit()
            }
            .accessibilityIdentifier("SettingsTerminalGhosttyFontSizeStepper")
        }
    }

    @ViewBuilder
    private var cursorRows: some View {
        optionRow(
            "cursor-style",
            String(localized: "settings.terminal.ghostty.cursorStyle", defaultValue: "Cursor Style"),
            key: .cursorStyle,
            controlWidth: 280
        ) {
            Picker("", selection: Binding(get: { options.cursorStyle }, set: { apply(.cursorStyle($0)) })) {
                ForEach(GhosttyCursorStyle.allCases, id: \.self) { style in
                    Text(cursorStyleTitle(style)).tag(style)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityIdentifier("SettingsTerminalGhosttyCursorStylePicker")
        }
        SettingsCardDivider()
        optionRow(
            "cursor-blink",
            String(localized: "settings.terminal.ghostty.cursorBlink", defaultValue: "Blinking Cursor"),
            key: .cursorStyleBlink
        ) {
            Toggle("", isOn: Binding(get: { options.cursorBlinks }, set: { apply(.cursorBlinks($0)) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsTerminalGhosttyCursorBlinkToggle")
        }
    }

    @ViewBuilder
    private var windowRows: some View {
        optionRow(
            "window-padding-x",
            String(localized: "settings.terminal.ghostty.windowPaddingX", defaultValue: "Horizontal Padding"),
            key: .windowPaddingX,
            controlWidth: 140
        ) {
            paddingStepper(options.windowPaddingX.leading, identifier: "SettingsTerminalGhosttyPaddingXStepper") {
                apply(.windowPaddingX(options.windowPaddingX.withLeading($0)))
            }
        }
        SettingsCardDivider()
        optionRow(
            "window-padding-y",
            String(localized: "settings.terminal.ghostty.windowPaddingY", defaultValue: "Vertical Padding"),
            key: .windowPaddingY,
            controlWidth: 140
        ) {
            paddingStepper(options.windowPaddingY.leading, identifier: "SettingsTerminalGhosttyPaddingYStepper") {
                apply(.windowPaddingY(options.windowPaddingY.withLeading($0)))
            }
        }
        SettingsCardDivider()
        optionRow(
            "background-opacity",
            String(localized: "settings.terminal.ghostty.backgroundOpacity", defaultValue: "Background Opacity"),
            key: .backgroundOpacity,
            controlWidth: 200
        ) {
            HStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { activeOpacityDragValue ?? options.backgroundOpacity },
                        set: { activeOpacityDragValue = $0 }
                    ),
                    in: 0...1,
                    step: 0.05
                ) { editing in
                    guard !editing, let value = activeOpacityDragValue else { return }
                    activeOpacityDragValue = nil
                    apply(.backgroundOpacity(value))
                }
                .frame(width: 140)
                .accessibilityIdentifier("SettingsTerminalGhosttyBackgroundOpacitySlider")

                Text(activeOpacityDragValue ?? options.backgroundOpacity, format: .percent.precision(.fractionLength(0)))
                    .cmuxFont(size: 12, weight: .medium, design: .rounded)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
        SettingsCardDivider()
        optionRow(
            "background-blur",
            String(localized: "settings.terminal.ghostty.backgroundBlur", defaultValue: "Background Blur"),
            key: .backgroundBlur
        ) {
            Toggle("", isOn: Binding(get: { options.backgroundBlurEnabled }, set: { apply(.backgroundBlurEnabled($0)) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsTerminalGhosttyBackgroundBlurToggle")
        }
    }

    @ViewBuilder
    private var inputRows: some View {
        optionRow(
            "option-as-alt",
            String(localized: "settings.terminal.ghostty.optionAsAlt", defaultValue: "Option as Alt"),
            key: .macosOptionAsAlt,
            controlWidth: 160
        ) {
            Picker("", selection: Binding(get: { options.optionAsAlt }, set: { apply(.optionAsAlt($0)) })) {
                ForEach(GhosttyOptionAsAlt.allCases, id: \.self) { option in
                    Text(optionAsAltTitle(option)).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier("SettingsTerminalGhosttyOptionAsAltPicker")
        }
        SettingsCardDivider()
        optionRow(
            "scrollback-limit",
            String(localized: "settings.terminal.ghostty.scrollbackLimit", defaultValue: "Scrollback Limit"),
            key: .scrollbackLimit,
            detail: String(
                localized: "settings.terminal.ghostty.scrollbackLimit.newTerminals",
                defaultValue: "Applies to new terminals."
            ),
            controlWidth: 140
        ) {
            HStack(spacing: 6) {
                TextField("", value: Binding(
                    get: { Int((Double(options.scrollbackLimitBytes) / Double(Self.bytesPerMegabyte)).rounded()) },
                    set: { apply(.scrollbackLimitBytes(min(max($0, 0), 100_000) * Self.bytesPerMegabyte)) }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .accessibilityIdentifier("SettingsTerminalGhosttyScrollbackLimitField")
                .accessibilityLabel(String(localized: "settings.terminal.ghostty.scrollbackLimit", defaultValue: "Scrollback Limit"))

                Text(String(localized: "settings.terminal.ghostty.scrollbackLimit.unit", defaultValue: "MB"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Helpers

    /// A row captioned with its Ghostty key (and `detail`, when given), with an
    /// override note beneath it when a later-loading file beats the written value.
    private func optionRow<Control: View>(
        _ id: String,
        _ title: String,
        key: GhosttyTerminalOptionKey,
        detail: String? = nil,
        controlWidth: CGFloat? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:terminal:\(id)",
                title,
                subtitle: [key.rawValue, detail].compactMap { $0 }.joined(separator: " · "),
                controlWidth: controlWidth,
                trailing: control
            )
            if let path = overriddenKeys[key] {
                Text(String.localizedStringWithFormat(
                    String(
                        localized: "settings.terminal.ghostty.overridden",
                        defaultValue: "Overridden by your config (%@)"
                    ),
                    path
                ))
                .cmuxFont(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func paddingStepper(
        _ points: Int,
        identifier: String,
        set: @escaping (Int) -> Void
    ) -> some View {
        Stepper(value: Binding(get: { points }, set: set), in: 0...200) {
            Text(String.localizedStringWithFormat(
                String(localized: "settings.fontSize.valuePoints", defaultValue: "%@ pt"),
                String(points)
            ))
            .monospacedDigit()
        }
        .accessibilityIdentifier(identifier)
    }

    /// Installed monospaced families, plus the configured family when it isn't
    /// flagged fixed-pitch, so the picker always shows the current choice.
    private var fontFamilyChoices: [String] {
        guard let current = options.fontFamily, !monospacedFamilies.contains(current) else {
            return monospacedFamilies
        }
        return ([current] + monospacedFamilies).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func cursorStyleTitle(_ style: GhosttyCursorStyle) -> String {
        switch style {
        case .block:
            return String(localized: "settings.terminal.ghostty.cursorStyle.block", defaultValue: "Block")
        case .bar:
            return String(localized: "settings.terminal.ghostty.cursorStyle.bar", defaultValue: "Bar")
        case .underline:
            return String(localized: "settings.terminal.ghostty.cursorStyle.underline", defaultValue: "Underline")
        case .blockHollow:
            return String(localized: "settings.terminal.ghostty.cursorStyle.blockHollow", defaultValue: "Hollow")
        }
    }

    private func optionAsAltTitle(_ option: GhosttyOptionAsAlt) -> String {
        switch option {
        case .automatic:
            return String(localized: "settings.terminal.ghostty.optionAsAlt.automatic", defaultValue: "Automatic")
        case .off:
            return String(localized: "settings.terminal.ghostty.optionAsAlt.off", defaultValue: "Off")
        case .left:
            return String(localized: "settings.terminal.ghostty.optionAsAlt.left", defaultValue: "Left Option")
        case .right:
            return String(localized: "settings.terminal.ghostty.optionAsAlt.right", defaultValue: "Right Option")
        case .both:
            return String(localized: "settings.terminal.ghostty.optionAsAlt.both", defaultValue: "Both Option Keys")
        }
    }

    // MARK: Loading and saving

    private func load() async {
        let families = Task.detached(priority: .utility) { MonospacedFontFamilies().load() }
        options = await hostActions.terminalGhosttyOptions().options
        hasLoaded = true
        monospacedFamilies = await families.value
    }

    /// Shows `change` right away, then writes it after a short pause (a newer
    /// change to the same key replaces this task, so stepper autorepeat writes
    /// once), and re-reads the effective values. When a later-loading config
    /// file still overrides the key, the row names that file instead of
    /// silently snapping back.
    private func apply(_ change: GhosttyTerminalOptionChange) {
        let key = change.key
        options = options.applying(change)
        pendingChanges[key] = change
        tasks.replaceOnMainActor(key) {
            try? await Task.sleep(for: Self.writeDelay)
            guard !Task.isCancelled else { return }
            let saved = await hostActions.applyTerminalGhosttyOption(change)
            guard !Task.isCancelled else { return }
            pendingChanges[key] = nil
            saveFailed = !saved
            let snapshot = await hostActions.terminalGhosttyOptions()
            overriddenKeys[key] = saved && !snapshot.options.reflects(change)
                ? snapshot.sourcePaths[key]
                : nil
            options = pendingChanges.values.reduce(snapshot.options) { $0.applying($1) }
        }
    }
}

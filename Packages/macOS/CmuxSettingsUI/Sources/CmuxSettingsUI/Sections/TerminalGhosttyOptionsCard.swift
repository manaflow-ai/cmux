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
    @State private var tasks = MainActorTaskStore<String>()

    private static let bytesPerMegabyte = 1_000_000

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
                set: { apply(.fontFamily($0.isEmpty ? nil : $0)) }
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
            paddingStepper(options.windowPaddingX, identifier: "SettingsTerminalGhosttyPaddingXStepper") {
                apply(.windowPaddingX($0))
            }
        }
        SettingsCardDivider()
        optionRow(
            "window-padding-y",
            String(localized: "settings.terminal.ghostty.windowPaddingY", defaultValue: "Vertical Padding"),
            key: .windowPaddingY,
            controlWidth: 140
        ) {
            paddingStepper(options.windowPaddingY, identifier: "SettingsTerminalGhosttyPaddingYStepper") {
                apply(.windowPaddingY($0))
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

    private func optionRow<Control: View>(
        _ id: String,
        _ title: String,
        key: GhosttyTerminalOptionKey,
        controlWidth: CGFloat? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:terminal:\(id)",
            title,
            subtitle: key.rawValue,
            controlWidth: controlWidth,
            trailing: control
        )
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
        options = await hostActions.terminalGhosttyOptions()
        hasLoaded = true
        monospacedFamilies = await families.value
    }

    /// Shows `change` right away, writes it, then re-reads the effective values
    /// so a later-loading include that still overrides the key shows through.
    private func apply(_ change: GhosttyTerminalOptionChange) {
        options = options.applying(change)
        tasks.replaceOnMainActor("apply") {
            let saved = await hostActions.applyTerminalGhosttyOption(change)
            guard !Task.isCancelled else { return }
            saveFailed = !saved
            let effective = await hostActions.terminalGhosttyOptions()
            guard !Task.isCancelled else { return }
            options = effective
        }
    }
}

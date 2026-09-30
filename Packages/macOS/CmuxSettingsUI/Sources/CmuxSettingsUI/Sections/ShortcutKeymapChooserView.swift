import CmuxFoundation
import CmuxSettings
import SwiftUI

extension ShortcutKeymapPreset {
    /// One line describing the style, shown under its name in the chooser.
    public var chooserDescription: String {
        switch self {
        case .cmux:
            return String(
                localized: "shortcut.keymap.chooser.description.cmux",
                defaultValue: "cmux's own layout. Bracket keys walk the tab bar and ⌘1…9 picks a workspace."
            )
        case .iTerm2:
            return String(
                localized: "shortcut.keymap.chooser.description.iterm2",
                defaultValue: "What iTerm2 users expect. ⌘1…9 picks a tab in the focused pane."
            )
        case .terminal:
            return String(
                localized: "shortcut.keymap.chooser.description.terminal",
                defaultValue: "What Terminal.app users expect, including its shifted bracket keys."
            )
        case .tmux:
            return String(
                localized: "shortcut.keymap.chooser.description.tmux",
                defaultValue: "A ⌃B prefix, the way tmux does it, for muscle memory built in a multiplexer."
            )
        case .browser:
            return String(
                localized: "shortcut.keymap.chooser.description.browser",
                defaultValue: "A browser's tab keys. ⌃Tab walks the tab bar and ⌘1…9 jumps to one."
            )
        }
    }
}

/// The base keymap chooser: pick a shortcut style and see what it does before
/// committing to it.
///
/// This is the question a game asks at first launch, WASD or arrow keys. It
/// opens once on a fresh install and is reachable from Settings and the
/// Command Palette forever after.
///
/// The preview describes each preset on a clean install, which is the question
/// being asked, so it renders without reading the config file. Only Apply
/// touches disk, through ``onApply``, which lets the first-run window and the
/// Settings sheet share this view.
@MainActor
public struct ShortcutKeymapChooserView: View {
    /// The preset shown as selected when the chooser opens.
    private let initialPreset: ShortcutKeymapPreset
    /// The preset the config file is on now, marked in the list. `nil` when the
    /// file mixes presets or has not loaded.
    private let currentPreset: ShortcutKeymapPreset?
    /// Writes the chosen preset. The chooser stays up until this succeeds.
    private let onApply: (ShortcutKeymapPreset) async -> Bool
    /// Closes the chooser without writing anything.
    private let onKeepCurrent: () -> Void
    /// The host's factory defaults, so the preview shows the keys this build
    /// actually ships rather than the package's built-in table.
    private let defaultShortcutResolver: ShortcutDefaultResolver

    @State private var selection: ShortcutKeymapPreset
    @State private var isApplying = false
    @State private var applyError: String?

    /// Creates the chooser.
    ///
    /// - Parameters:
    ///   - initialPreset: The preset selected when the chooser opens. Pass the
    ///     current preset from Settings, or ``ShortcutKeymapPreset/cmux`` on a
    ///     first run so the default is what someone gets by pressing Return.
    ///   - currentPreset: The preset in the file now, marked in the list.
    ///   - onApply: Writes the chosen preset and returns whether it succeeded.
    ///   - onKeepCurrent: Closes the chooser without writing.
    ///   - defaultShortcutResolver: The host's factory defaults for the preview.
    public init(
        initialPreset: ShortcutKeymapPreset = .cmux,
        currentPreset: ShortcutKeymapPreset? = nil,
        onApply: @escaping (ShortcutKeymapPreset) async -> Bool,
        onKeepCurrent: @escaping () -> Void,
        defaultShortcutResolver: ShortcutDefaultResolver = .builtIn
    ) {
        self.initialPreset = initialPreset
        self.currentPreset = currentPreset
        self.onApply = onApply
        self.onKeepCurrent = onKeepCurrent
        self.defaultShortcutResolver = defaultShortcutResolver
        _selection = State(initialValue: initialPreset)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            HStack(alignment: .top, spacing: 18) {
                presetList
                    .frame(width: 260)
                preview
                    .frame(minWidth: 280, alignment: .leading)
            }
            footer
        }
        .padding(24)
        .frame(minWidth: 620)
        .accessibilityIdentifier("KeymapChooser")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(String(
                localized: "shortcut.keymap.chooser.title",
                defaultValue: "Choose your keyboard shortcuts"
            ))
            .cmuxFont(.title2)
            Text(String(
                localized: "shortcut.keymap.chooser.subtitle",
                defaultValue: "Pick the style your fingers already know. Nothing else changes, and you can switch any time in Settings > Keyboard Shortcuts."
            ))
            .cmuxFont(.callout)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ShortcutKeymapPreset.allCases, id: \.self) { preset in
                presetCard(preset)
            }
        }
    }

    private func presetCard(_ preset: ShortcutKeymapPreset) -> some View {
        let isSelected = preset == selection
        return Button {
            selection = preset
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(preset.displayName)
                            .cmuxFont(.body, weight: .semibold)
                        if preset == currentPreset {
                            Text(String(
                                localized: "shortcut.keymap.chooser.current",
                                defaultValue: "Current"
                            ))
                            .cmuxFont(.caption)
                            .foregroundColor(.secondary)
                        }
                    }
                    Text(preset.chooserDescription)
                        .cmuxFont(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(isApplying)
        .accessibilityIdentifier("KeymapChooserPreset-\(preset.rawValue)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The live preview: the same rows for every style, so switching selection
    /// reads as a column changing rather than a new list appearing.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(String(
                localized: "shortcut.keymap.chooser.previewTitle",
                defaultValue: "What this does"
            ))
            .cmuxFont(.caption)
            .foregroundColor(.secondary)
            ForEach(
                selection.highlights(defaultShortcutResolver: defaultShortcutResolver),
                id: \.action
            ) { highlight in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(highlight.action.displayName)
                        .cmuxFont(.callout)
                        .foregroundColor(highlight.isWrittenByPreset ? .primary : .secondary)
                    Spacer(minLength: 12)
                    Text(shortcutDisplayString(
                        highlight.shortcut,
                        numbered: highlight.usesNumberedDigitRange
                    ))
                    .cmuxFont(.callout, weight: .semibold, monospacedDigit: true)
                    .foregroundColor(highlight.isWrittenByPreset ? .primary : .secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(String(
                    localized: "shortcut.keymap.chooser.previewLegend",
                    defaultValue: "Dimmed keys are the same in every style."
                ))
                let others = selection.overridesBeyondHighlights
                if others > 0 {
                    Text(String(
                        format: String(
                            localized: "shortcut.keymap.chooser.previewMore",
                            defaultValue: "This style also changes %ld other shortcuts, all listed in Settings > Keyboard Shortcuts."
                        ),
                        others
                    ))
                    .accessibilityIdentifier("KeymapChooserPreviewMore")
                }
            }
            .cmuxFont(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
        }
        .accessibilityIdentifier("KeymapChooserPreview")
    }

    private var footer: some View {
        VStack(alignment: .trailing, spacing: 9) {
            if let applyError {
                Label(applyError, systemImage: "exclamationmark.triangle")
                    .cmuxFont(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("KeymapChooserApplyError")
            }
            HStack(spacing: 9) {
                Spacer()
                Button(String(
                    localized: "shortcut.keymap.chooser.keepCurrent",
                    defaultValue: "Not Now"
                )) {
                    onKeepCurrent()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isApplying)
                .accessibilityIdentifier("KeymapChooserKeepCurrent")
                Button(String(
                    localized: "shortcut.keymap.chooser.apply",
                    defaultValue: "Use These Shortcuts"
                )) {
                    apply()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isApplying)
                .accessibilityIdentifier("KeymapChooserApply")
            }
        }
    }

    private func apply() {
        guard !isApplying else { return }
        isApplying = true
        applyError = nil
        let preset = selection
        Task {
            let didApply = await onApply(preset)
            if !didApply {
                applyError = String(
                    localized: "shortcut.keymap.chooser.applyFailed",
                    defaultValue: "Couldn't save this keymap. Please try again."
                )
            }
            isApplying = false
        }
    }
}

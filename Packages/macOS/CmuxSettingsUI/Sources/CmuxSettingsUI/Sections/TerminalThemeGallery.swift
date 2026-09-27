import AppKit
import CmuxFoundation
import SwiftUI

/// The Terminal section's theme rows: the current light and dark themes, a
/// Revert button while a pick is being previewed, the `cmux themes` terminal
/// picker as a secondary path, and a gallery of theme cards below.
@MainActor
struct TerminalThemeSettingsRows: View {
    let hostActions: SettingsHostActions
    @State private var model: TerminalThemeGalleryModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(localized: "settings.app.theme", defaultValue: "Theme"),
                subtitle: model.map { Self.subtitle(for: $0.selection) }
            ) {
                HStack(spacing: 8) {
                    if let model, model.hasPendingChange {
                        Button(String(localized: "settings.terminal.themeGallery.revert", defaultValue: "Revert", bundle: .module)) {
                            model.revert()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("SettingsTerminalThemeRevertButton")
                    }
                    Button(
                        String(localized: "settings.terminal.themeGallery.openInTerminal", defaultValue: "Open in Terminal…", bundle: .module)
                    ) {
                        hostActions.openTerminalThemePicker()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(
                        String(
                            localized: "settings.terminal.themeGallery.openInTerminal.help",
                            defaultValue: "Runs the searchable cmux themes picker in a new terminal tab.",
                            bundle: .module
                        )
                    )
                    .accessibilityIdentifier("SettingsTerminalThemePickerButton")
                }
            }
            if let model {
                TerminalThemeGalleryView(model: model)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .task {
            let galleryModel: TerminalThemeGalleryModel
            if let model {
                galleryModel = model
                galleryModel.refreshSelection()
            } else {
                // Built on first appearance, not in init: the context reads config files.
                guard let context = hostActions.terminalThemeGalleryContext() else { return }
                galleryModel = TerminalThemeGalleryModel(context: context) { [weak hostActions] phase in
                    hostActions?.terminalThemeConfigDidChange(phase: phase)
                }
                model = galleryModel
            }
            await galleryModel.load()
        }
    }

    private static func subtitle(for selection: CmuxTerminalThemePair) -> String {
        let defaultName = String(
            localized: "settings.terminal.themeGallery.default",
            defaultValue: "Ghostty default colors",
            bundle: .module
        )
        let light = selection.light ?? defaultName
        let dark = selection.dark ?? defaultName
        if light.caseInsensitiveCompare(dark) == .orderedSame {
            return light
        }
        return String.localizedStringWithFormat(
            String(localized: "settings.terminal.themeGallery.pair", defaultValue: "Light: %1$@ · Dark: %2$@", bundle: .module),
            light,
            dark
        )
    }
}

/// Slot picker, search field and card grid for ``TerminalThemeGalleryModel``.
@MainActor
private struct TerminalThemeGalleryView: View {
    @Bindable var model: TerminalThemeGalleryModel

    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 220), spacing: 10, alignment: .top)]

    var body: some View {
        let results = model.results
        let selectedName = model.selectedName(for: model.slot)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker(
                    String(localized: "settings.terminal.themeGallery.slot", defaultValue: "Appearance", bundle: .module),
                    selection: $model.slot
                ) {
                    Text(String(localized: "appearance.light", defaultValue: "Light"))
                        .tag(TerminalThemeGalleryModel.Slot.light)
                    Text(String(localized: "appearance.dark", defaultValue: "Dark"))
                        .tag(TerminalThemeGalleryModel.Slot.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("SettingsTerminalThemeSlotPicker")

                Spacer(minLength: 8)

                TextField(
                    String(localized: "settings.terminal.themeGallery.search", defaultValue: "Search all themes", bundle: .module),
                    text: $model.query
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 200)
                .accessibilityIdentifier("SettingsTerminalThemeSearchField")
            }

            if !model.isLoaded {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if results.themes.isEmpty {
                Text(String(localized: "settings.terminal.themeGallery.noResults", defaultValue: "No themes match your search.", bundle: .module))
                    .cmuxFont(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(results.themes) { theme in
                        TerminalThemeCard(
                            theme: theme,
                            isSelected: Self.matches(theme.name, selectedName),
                            usedInLight: Self.matches(theme.name, model.selection.light),
                            usedInDark: Self.matches(theme.name, model.selection.dark),
                            onSelect: { model.select(theme.name) }
                        )
                    }
                }
                if results.isTruncated {
                    Text(
                        String(
                            localized: "settings.terminal.themeGallery.truncated",
                            defaultValue: "More themes match. Keep typing to narrow the list.",
                            bundle: .module
                        )
                    )
                    .cmuxFont(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if model.writeFailed {
                Text(
                    String(
                        localized: "settings.terminal.themeGallery.writeFailed",
                        defaultValue: "Couldn't save the terminal theme. Please try again.",
                        bundle: .module
                    )
                )
                .cmuxFont(.caption)
                .foregroundStyle(.red)
            }
        }
        .accessibilityIdentifier("SettingsTerminalThemeGallery")
    }

    private static func matches(_ name: String, _ other: String?) -> Bool {
        guard let other else { return false }
        return name.caseInsensitiveCompare(other) == .orderedSame
    }
}

/// One theme card: the theme's background with its name in its foreground
/// color, a cursor block, and its 16 ANSI colors as two swatch rows.
@MainActor
private struct TerminalThemeCard: View {
    let theme: TerminalThemeGalleryModel.Theme
    let isSelected: Bool
    let usedInLight: Bool
    let usedInDark: Bool
    let onSelect: () -> Void

    var body: some View {
        let colors = theme.colors
        let background = colors.background?.color ?? Color(nsColor: .textBackgroundColor)
        let foreground = colors.foreground?.color ?? Color(nsColor: .textColor)

        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 5) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 4) {
                        Text(verbatim: theme.name)
                            .cmuxFont(size: 10, weight: .medium, design: .monospaced)
                            .foregroundStyle(foreground)
                            .lineLimit(1)
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(colors.cursor?.color ?? foreground)
                            .frame(width: 5, height: 11)
                    }
                    swatchRow(colors: colors, range: 0..<8)
                    swatchRow(colors: colors, range: 8..<16)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )

                HStack(spacing: 4) {
                    if usedInLight {
                        badge(String(localized: "appearance.light", defaultValue: "Light"))
                    }
                    if usedInDark {
                        badge(String(localized: "appearance.dark", defaultValue: "Dark"))
                    }
                }
                .frame(height: 14)
            }
            .padding(5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: theme.name))
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(Text(verbatim: theme.name))
    }

    /// Says which appearances use this theme, or nothing when neither does.
    private var accessibilityValue: String {
        switch (usedInLight, usedInDark) {
        case (true, true):
            String(
                localized: "settings.terminal.themeGallery.card.lightAndDark",
                defaultValue: "Current light and dark theme",
                bundle: .module
            )
        case (true, false):
            String(
                localized: "settings.terminal.themeGallery.card.light",
                defaultValue: "Current light theme",
                bundle: .module
            )
        case (false, true):
            String(
                localized: "settings.terminal.themeGallery.card.dark",
                defaultValue: "Current dark theme",
                bundle: .module
            )
        case (false, false):
            ""
        }
    }

    private func swatchRow(colors: GhosttyThemeColors, range: Range<Int>) -> some View {
        HStack(spacing: 2) {
            ForEach(range, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(colors.palette[index]?.color ?? Color.clear)
                    .frame(height: 8)
            }
        }
    }

    private func badge(_ title: String) -> some View {
        Text(title)
            .cmuxFont(size: 9, weight: .medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}

private extension GhosttyThemeRGB {
    var color: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, opacity: 1)
    }
}

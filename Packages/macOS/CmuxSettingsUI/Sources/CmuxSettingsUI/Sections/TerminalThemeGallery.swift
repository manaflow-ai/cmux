import AppKit
import CmuxFoundation
import SwiftUI

/// The Themes section's terminal theme rows: the current light and dark themes, a
/// Revert button while a pick is being previewed, the `cmux themes` terminal
/// picker as a secondary path, and a gallery of theme cards below.
@MainActor
struct TerminalThemeSettingsRows: View {
    let hostActions: SettingsHostActions
    @State private var model: TerminalThemeGalleryModel?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:themes:terminal-theme",
                String(localized: "settings.terminal.theme", defaultValue: "Terminal Theme"),
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
        .onChange(of: colorScheme) { _, newScheme in
            model?.appearanceDidChange(prefersDark: newScheme == .dark)
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

/// Search field and card grid for ``TerminalThemeGalleryModel``.
@MainActor
private struct TerminalThemeGalleryView: View {
    @Bindable var model: TerminalThemeGalleryModel

    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 220), spacing: 10, alignment: .top)]

    var body: some View {
        let results = model.results
        let selectedName = model.themeInUse

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
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
                themeGroup(results.matchingSlot, isDark: model.slotInUse == .dark, selectedName: selectedName)
                themeGroup(results.otherAppearance, isDark: model.slotInUse != .dark, selectedName: selectedName)
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

    /// One appearance's cards under a "Dark Themes" or "Light Themes" heading.
    @ViewBuilder
    private func themeGroup(
        _ themes: [TerminalThemeGalleryModel.Theme],
        isDark: Bool,
        selectedName: String?
    ) -> some View {
        if !themes.isEmpty {
            Text(Self.groupTitle(isDark: isDark))
                .cmuxFont(.caption, weight: .semibold)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(themes) { theme in
                    TerminalThemeCard(
                        theme: theme,
                        isSelected: Self.matches(theme.name, selectedName),
                        onSelect: { model.select(theme.name) }
                    )
                    .equatable()
                }
            }
        }
    }

    private static func groupTitle(isDark: Bool) -> String {
        isDark
            ? String(localized: "settings.terminal.themeGallery.darkGroup", defaultValue: "Dark Themes", bundle: .module)
            : String(localized: "settings.terminal.themeGallery.lightGroup", defaultValue: "Light Themes", bundle: .module)
    }

    private static func matches(_ name: String, _ other: String?) -> Bool {
        guard let other else { return false }
        return name.caseInsensitiveCompare(other) == .orderedSame
    }
}

/// One theme card: the theme's background with its name in its foreground
/// color, a cursor block, and its 16 ANSI colors as two swatch rows.
///
/// Cards are built as they scroll into view, so each keeps its view count
/// small: the background and swatches are one `Canvas`, colors are resolved
/// once in ``TerminalThemeGalleryModel/PreviewColors``, and `Equatable` lets
/// SwiftUI skip cards whose theme and selection did not change.
struct TerminalThemeCard: View, Equatable {
    @Environment(\.settingsSelectionStyle) private var selectionStyle
    let theme: TerminalThemeGalleryModel.Theme
    let isSelected: Bool
    let onSelect: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.theme.name == rhs.theme.name && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        let preview = theme.preview
        let foreground = preview.foreground ?? Color(nsColor: .textColor)

        Button(action: onSelect) {
            HStack(spacing: 4) {
                Text(verbatim: theme.name)
                    .cmuxFont(size: 10, weight: .medium, design: .monospaced)
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(preview.cursor ?? foreground)
                    .frame(width: 5, height: 11)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, minHeight: Self.previewHeight, alignment: .topLeading)
            .background(TerminalThemeSwatches(preview: preview))
            .padding(5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? selectionStyle.selectedFill : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? selectionStyle.selectedStroke : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: theme.name))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // Long names truncate; only realized cards pay for the tooltip.
        .help(Text(verbatim: theme.name))
    }

    /// Height of the drawn preview: name row plus two swatch rows.
    static let previewHeight: CGFloat = 54
}

/// The card's background and its two rows of eight ANSI swatches, drawn in
/// one pass.
private struct TerminalThemeSwatches: View {
    let preview: TerminalThemeGalleryModel.PreviewColors

    var body: some View {
        Canvas { context, size in
            let card = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6, style: .continuous)
            context.fill(card, with: .color(preview.background ?? Color(nsColor: .textBackgroundColor)))
            context.stroke(card, with: .color(Color.primary.opacity(0.1)), lineWidth: 1)

            let inset: CGFloat = 8
            let spacing: CGFloat = 2
            let swatchHeight: CGFloat = 8
            let width = (size.width - inset * 2 - spacing * 7) / 8
            for row in 0..<2 {
                let y = size.height - inset - swatchHeight - CGFloat(1 - row) * (swatchHeight + 7)
                for column in 0..<8 {
                    guard let color = preview.palette[row * 8 + column] else { continue }
                    let rect = CGRect(x: inset + CGFloat(column) * (width + spacing), y: y, width: width, height: swatchHeight)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2, style: .continuous), with: .color(color))
                }
            }
        }
    }
}

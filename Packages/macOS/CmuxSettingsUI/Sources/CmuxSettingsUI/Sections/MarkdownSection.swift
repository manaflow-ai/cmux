import CmuxFoundation
import CmuxSettings
import Foundation
import SwiftUI

/// **Markdown** section — settings for the built-in markdown viewer:
/// open-in-viewer routing, typography (font size, family, reading width), and
/// wiki-style link parsing.
@MainActor
public struct MarkdownSection: View {
    @State private var openMarkdown: DefaultsValueModel<Bool>
    @State private var fontSize: DefaultsValueModel<Int>
    @State private var fontFamily: DefaultsValueModel<String>
    @State private var maxWidth: DefaultsValueModel<Int>
    @State private var wikiLinks: DefaultsValueModel<Bool>
    @State private var wikiLinkAnchor: DefaultsValueModel<MarkdownWikiLinkAnchor>

    private static let columnWidth: CGFloat = 196

    /// Creates the Markdown settings section.
    ///
    /// - Parameters:
    ///   - defaultsStore: The store used to read and write markdown settings.
    ///   - catalog: The catalog that provides the markdown-related setting keys.
    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _openMarkdown = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.openMarkdownInCmuxViewer))
        _fontSize = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.markdown.fontSize))
        _fontFamily = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.markdown.fontFamily))
        _maxWidth = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.markdown.maxWidth))
        _wikiLinks = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.markdown.wikiLinks))
        _wikiLinkAnchor = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.markdown.wikiLinkAnchor))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.markdown", defaultValue: "Markdown"), section: .markdown)
                .accessibilityIdentifier("SettingsMarkdownSection")
            SettingsCard {
                openInViewerRow
                SettingsCardDivider()
                fontSizeRow
                SettingsCardDivider()
                maxWidthRow
                SettingsCardDivider()
                fontFamilyRow
                SettingsCardDivider()
                wikiLinksRow
                SettingsCardDivider()
                wikiLinkAnchorRow
            }
        }
        .task { startObservingSettings() }
    }

    private func startObservingSettings() {
        let models: [any SettingObservationStarting] = [
            openMarkdown, fontSize, fontFamily, maxWidth, wikiLinks, wikiLinkAnchor,
        ]
        models.forEach { $0.startObserving() }
    }

    @ViewBuilder
    private var openInViewerRow: some View {
        SettingsCardRow(
            configurationReview: .json("app.openMarkdownInCmuxViewer"),
            String(localized: "settings.app.openMarkdownInCmuxViewer", defaultValue: "Open Markdown in cmux Viewer"),
            subtitle: String(localized: "settings.app.openMarkdownInCmuxViewer.subtitle", defaultValue: "When supported file routing is on, Cmd-clicking Markdown files opens the rendered cmux markdown viewer instead of the generic file preview.")
        ) {
            Toggle("", isOn: Binding(get: { openMarkdown.current }, set: { openMarkdown.set($0) }))
                .labelsHidden()
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var fontSizeRow: some View {
        SettingsCardRow(
            configurationReview: .json("markdown.fontSize"),
            String(localized: "settings.app.markdownFontSize", defaultValue: "Markdown Viewer Font Size"),
            subtitle: String(localized: "settings.app.markdownFontSize.subtitle", defaultValue: "Default body font size, in points, for newly opened markdown viewers. Zoom a viewer live with Cmd-+ / Cmd-- / Cmd-0."),
            controlWidth: Self.columnWidth
        ) {
            Stepper(
                value: Binding(get: { fontSize.current }, set: { fontSize.set($0) }),
                in: 8...96
            ) {
                Text(verbatim: "\(fontSize.current)")
                    .monospacedDigit()
                    .frame(width: 28, alignment: .trailing)
            }
            .controlSize(.small)
            .accessibilityIdentifier("SettingsMarkdownFontSizeStepper")
            .accessibilityLabel(
                String(localized: "settings.app.markdownFontSize", defaultValue: "Markdown Viewer Font Size")
            )
        }
    }

    @ViewBuilder
    private var maxWidthRow: some View {
        SettingsCardRow(
            configurationReview: .json("markdown.maxWidth"),
            String(localized: "settings.app.markdownMaxWidth", defaultValue: "Markdown Viewer Max Width"),
            subtitle: String(localized: "settings.app.markdownMaxWidth.subtitle", defaultValue: "Default maximum reading column width, in CSS pixels, for newly opened markdown viewers."),
            controlWidth: Self.columnWidth
        ) {
            Stepper(
                value: Binding(get: { maxWidth.current }, set: { maxWidth.set($0) }),
                in: 320...2400,
                step: 20
            ) {
                Text(verbatim: "\(maxWidth.current)")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
            .controlSize(.small)
            .accessibilityIdentifier("SettingsMarkdownMaxWidthStepper")
            .accessibilityLabel(
                String(localized: "settings.app.markdownMaxWidth", defaultValue: "Markdown Viewer Max Width")
            )
        }
    }

    @ViewBuilder
    private var fontFamilyRow: some View {
        SettingsCardRow(
            configurationReview: .json("markdown.fontFamily"),
            String(localized: "settings.app.markdownFontFamily", defaultValue: "Markdown Viewer Font"),
            subtitle: String(localized: "settings.app.markdownFontFamily.subtitle", defaultValue: "Default body font family for newly opened markdown viewers. Leave empty for the system markdown font stack.")
        ) {
            TextField(
                String(localized: "settings.app.markdownFontFamily.placeholder", defaultValue: "System"),
                text: Binding(get: { fontFamily.current }, set: { fontFamily.set($0) })
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 200)
            .accessibilityIdentifier("SettingsMarkdownFontFamilyTextField")
        }
    }

    @ViewBuilder
    private var wikiLinksRow: some View {
        SettingsCardRow(
            configurationReview: .json("markdown.wikiLinks"),
            String(localized: "settings.app.markdownWikiLinks", defaultValue: "Wiki Links"),
            subtitle: String(localized: "settings.app.markdownWikiLinks.subtitle", defaultValue: "Parse [[Note]] and [[Note|Label]] links in the viewer, resolving to notes anywhere under the anchor folder set below. A plain click opens the note in the current pane; Cmd-click opens a new tab. Off by default so ordinary [[...]] text renders literally.")
        ) {
            Toggle("", isOn: Binding(get: { wikiLinks.current }, set: { wikiLinks.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsMarkdownWikiLinksToggle")
        }
    }

    @ViewBuilder
    private var wikiLinkAnchorRow: some View {
        SettingsCardRow(
            configurationReview: .json("markdown.wikiLinkAnchor"),
            String(localized: "settings.app.markdownWikiLinkAnchor", defaultValue: "Wiki Link Anchor Folder"),
            subtitle: String(localized: "settings.app.markdownWikiLinkAnchor.subtitle", defaultValue: "The marker that anchors the top of your notes when resolving [[Wiki]] links: the nearest ancestor folder containing an Obsidian vault (.obsidian) or a Git repository (.git). Without a match, links resolve only to files in the same folder."),
            controlWidth: Self.columnWidth
        ) {
            Picker("", selection: Binding(get: { wikiLinkAnchor.current }, set: { wikiLinkAnchor.set($0) })) {
                Text(String(localized: "settings.app.markdownWikiLinkAnchor.obsidian", defaultValue: "Obsidian vault (.obsidian)")).tag(MarkdownWikiLinkAnchor.obsidian)
                Text(String(localized: "settings.app.markdownWikiLinkAnchor.git", defaultValue: "Git repository (.git)")).tag(MarkdownWikiLinkAnchor.git)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(!wikiLinks.current)
            .accessibilityIdentifier("SettingsMarkdownWikiLinkAnchorPicker")
        }
    }
}

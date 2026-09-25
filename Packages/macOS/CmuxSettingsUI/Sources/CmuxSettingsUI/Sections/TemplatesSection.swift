import CmuxSettings
import SwiftUI

/// Settings for the shared markdown and diff panel templates.
@MainActor
public struct TemplatesSection: View {
    private let catalog: SettingCatalog
    @State private var markdownFont: JSONValueModel<String>
    @State private var markdownFontSize: JSONValueModel<Double>
    @State private var markdownCSS: JSONValueModel<String>
    @State private var markdownHeader: JSONValueModel<String>
    @State private var notesFont: JSONValueModel<String>
    @State private var notesFontSize: JSONValueModel<Double>
    @State private var notesCSS: JSONValueModel<String>
    @State private var notesHeader: JSONValueModel<String>
    @State private var diffFont: JSONValueModel<String>
    @State private var diffFontSize: JSONValueModel<Double>
    @State private var diffCSS: JSONValueModel<String>
    @State private var diffHeader: JSONValueModel<String>

    public init(jsonStore: JSONConfigStore, errorLog: SettingsErrorLog) {
        let catalog = SettingCatalog()
        self.catalog = catalog
        _markdownFont = State(initialValue: JSONValueModel(store: jsonStore, key: catalog.templates.markdown.font, errorLog: errorLog))
        _markdownFontSize = State(initialValue: JSONValueModel(store: jsonStore, key: catalog.templates.markdown.fontSize, errorLog: errorLog))
        _markdownCSS = State(initialValue: JSONValueModel(store: jsonStore, key: catalog.templates.markdown.cssOverlay, errorLog: errorLog))
        _markdownHeader = State(initialValue: JSONValueModel(store: jsonStore, key: catalog.templates.markdown.headerExtensions, errorLog: errorLog))
        _notesFont = State(initialValue: JSONValueModel(store: jsonStore, key: catalog.templates.notes.font, errorLog: errorLog))
        _notesFontSize = State(initialValue: JSONValueModel(store: jsonStore, key: catalog.templates.notes.fontSize, errorLog: errorLog))
        _notesCSS = State(initialValue: JSONValueModel(store: jsonStore, key: catalog.templates.notes.cssOverlay, errorLog: errorLog))
        _notesHeader = State(initialValue: JSONValueModel(store: jsonStore, key: catalog.templates.notes.headerExtensions, errorLog: errorLog))
        _diffFont = State(initialValue: JSONValueModel(store: jsonStore, key: catalog.templates.diff.font, errorLog: errorLog))
        _diffFontSize = State(initialValue: JSONValueModel(store: jsonStore, key: catalog.templates.diff.fontSize, errorLog: errorLog))
        _diffCSS = State(initialValue: JSONValueModel(store: jsonStore, key: catalog.templates.diff.cssOverlay, errorLog: errorLog))
        _diffHeader = State(initialValue: JSONValueModel(store: jsonStore, key: catalog.templates.diff.headerExtensions, errorLog: errorLog))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(
                String(localized: "settings.section.templates", defaultValue: "Templates"),
                section: .templates
            )
            SettingsCard {
                templatePreview(
                    fontFamily: markdownFont.current,
                    fontSize: markdownFontSize.current,
                    sample: "# Markdown preview\nReadable body text and `inline code`."
                )
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .json("templates.markdown.font"),
                    String(localized: "settings.templates.markdownFont", defaultValue: "Markdown font"),
                    subtitle: String(localized: "settings.templates.markdownFont.subtitle", defaultValue: "Font family used by markdown panels. Leave empty for the system stack.")
                ) {
                    TextField(
                        String(localized: "settings.templates.font.placeholder", defaultValue: "System"),
                        text: Binding(get: { markdownFont.current }, set: { markdownFont.set($0) })
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                }
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .json("templates.markdown.fontSize"),
                    String(localized: "settings.templates.markdownFontSize", defaultValue: "Markdown font size"),
                    subtitle: String(localized: "settings.templates.markdownFontSize.subtitle", defaultValue: "Body size in points for newly rendered markdown panels.")
                ) {
                    Stepper(value: Binding(get: { markdownFontSize.current }, set: { markdownFontSize.set($0) }), in: 8...96, step: 1) {
                        Text(verbatim: "\(Int(markdownFontSize.current.rounded()))")
                            .monospacedDigit()
                    }
                    .controlSize(.small)
                }
                SettingsCardDivider()
                templateTextEditor(
                    key: "templates.markdown.cssOverlay",
                    title: String(localized: "settings.templates.cssOverlay", defaultValue: "Markdown CSS overlay"),
                    subtitle: String(localized: "settings.templates.cssOverlay.subtitle", defaultValue: "Raw CSS appended after cmux's markdown stylesheet."),
                    model: markdownCSS
                )
                SettingsCardDivider()
                templateTextEditor(
                    key: "templates.markdown.headerExtensions",
                    title: String(localized: "settings.templates.header", defaultValue: "Markdown header extension"),
                    subtitle: String(localized: "settings.templates.header.subtitle", defaultValue: "Markdown or HTML inserted before each rendered document."),
                    model: markdownHeader
                )
            }
            SettingsSectionHeader(
                String(localized: "settings.templates.notesHeader", defaultValue: "Notes template"),
                section: .templates
            )
            SettingsCard {
                templatePreview(
                    fontFamily: notesFont.current,
                    fontSize: notesFontSize.current,
                    sample: "# Note preview\nA project note rendered with this template."
                )
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .json("templates.notes.font"),
                    String(localized: "settings.templates.notesFont", defaultValue: "Notes font"),
                    subtitle: String(localized: "settings.templates.notesFont.subtitle", defaultValue: "Font family used by project-scoped notes.")
                ) {
                    TextField(
                        String(localized: "settings.templates.font.placeholder", defaultValue: "System"),
                        text: Binding(get: { notesFont.current }, set: { notesFont.set($0) })
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                }
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .json("templates.notes.fontSize"),
                    String(localized: "settings.templates.notesFontSize", defaultValue: "Notes font size"),
                    subtitle: String(localized: "settings.templates.notesFontSize.subtitle", defaultValue: "Body size in points for newly rendered notes.")
                ) {
                    Stepper(value: Binding(get: { notesFontSize.current }, set: { notesFontSize.set($0) }), in: 8...96, step: 1) {
                        Text(verbatim: "\(Int(notesFontSize.current.rounded()))")
                            .monospacedDigit()
                    }
                    .controlSize(.small)
                }
                SettingsCardDivider()
                templateTextEditor(
                    key: "templates.notes.cssOverlay",
                    title: String(localized: "settings.templates.notesCSSOverlay", defaultValue: "Notes CSS overlay"),
                    subtitle: String(localized: "settings.templates.notesCSSOverlay.subtitle", defaultValue: "Raw CSS appended after the notes stylesheet."),
                    model: notesCSS
                )
                SettingsCardDivider()
                templateTextEditor(
                    key: "templates.notes.headerExtensions",
                    title: String(localized: "settings.templates.notesHeaderExtension", defaultValue: "Notes header extension"),
                    subtitle: String(localized: "settings.templates.notesHeaderExtension.subtitle", defaultValue: "Markdown or HTML inserted before each rendered note."),
                    model: notesHeader
                )
            }
            SettingsSectionHeader(
                String(localized: "settings.templates.diffHeader", defaultValue: "Diff template"),
                section: .templates
            )
            SettingsCard {
                templatePreview(
                    fontFamily: diffFont.current,
                    fontSize: diffFontSize.current,
                    sample: "+ added line\n- removed line"
                )
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .json("templates.diff.font"),
                    String(localized: "settings.templates.diffFont", defaultValue: "Diff font"),
                    subtitle: String(localized: "settings.templates.diffFont.subtitle", defaultValue: "Code font used by diff panels.")
                ) {
                    TextField(
                        String(localized: "settings.templates.diffFont.placeholder", defaultValue: "Menlo"),
                        text: Binding(get: { diffFont.current }, set: { diffFont.set($0) })
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                }
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .json("templates.diff.fontSize"),
                    String(localized: "settings.templates.diffFontSize", defaultValue: "Diff font size"),
                    subtitle: String(localized: "settings.templates.diffFontSize.subtitle", defaultValue: "Code size in points for diff panels.")
                ) {
                    Stepper(value: Binding(get: { diffFontSize.current }, set: { diffFontSize.set($0) }), in: 8...96, step: 1) {
                        Text(verbatim: "\(Int(diffFontSize.current.rounded()))")
                            .monospacedDigit()
                    }
                    .controlSize(.small)
                }
                SettingsCardDivider()
                templateTextEditor(
                    key: "templates.diff.cssOverlay",
                    title: String(localized: "settings.templates.diffCSSOverlay", defaultValue: "Diff CSS overlay"),
                    subtitle: String(localized: "settings.templates.diffCSSOverlay.subtitle", defaultValue: "Raw CSS appended after cmux's diff stylesheet."),
                    model: diffCSS
                )
                SettingsCardDivider()
                templateTextEditor(
                    key: "templates.diff.headerExtensions",
                    title: String(localized: "settings.templates.diffHeaderExtension", defaultValue: "Diff header extension"),
                    subtitle: String(localized: "settings.templates.diffHeaderExtension.subtitle", defaultValue: "HTML inserted above each diff panel."),
                    model: diffHeader
                )
            }
        }
        .task {
            markdownFont.startObserving()
            markdownFontSize.startObserving()
            markdownCSS.startObserving()
            markdownHeader.startObserving()
            notesFont.startObserving()
            notesFontSize.startObserving()
            notesCSS.startObserving()
            notesHeader.startObserving()
            diffFont.startObserving()
            diffFontSize.startObserving()
            diffCSS.startObserving()
            diffHeader.startObserving()
        }
    }

    @ViewBuilder
    private func templatePreview(fontFamily: String, fontSize: Double, sample: String) -> some View {
        SettingsCardRow(
            String(localized: "settings.templates.preview", defaultValue: "Live preview"),
            subtitle: String(localized: "settings.templates.preview.subtitle", defaultValue: "Updates as you edit this template.")
        ) {
            Text(verbatim: sample)
                .font(fontFamily.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? .system(size: CGFloat(fontSize))
                    : .custom(fontFamily, size: CGFloat(fontSize)))
                .textSelection(.enabled)
                .padding(8)
                .frame(width: 340, alignment: .leading)
                .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private func templateTextEditor(
        key: String,
        title: String,
        subtitle: String,
        model: JSONValueModel<String>
    ) -> some View {
        SettingsCardRow(configurationReview: .json(key), title, subtitle: subtitle, controlWidth: 340) {
            TextEditor(text: Binding(get: { model.current }, set: { model.set($0) }))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 320, height: 64)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.25)))
        }
    }
}

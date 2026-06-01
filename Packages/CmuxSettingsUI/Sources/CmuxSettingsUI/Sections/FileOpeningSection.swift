import CmuxSettings
import SwiftUI

/// Settings section for file drops, file editor fallback, and command-click file extension routing.
@MainActor
public struct FileOpeningSection: View {
    @State private var fileDrop: DefaultsValueModel<FileDropDefaultBehavior>
    @State private var preferredEditor: DefaultsValueModel<String>
    @State private var fileExtensionOpeners: FileExtensionOpenersValueModel
    @State private var openSupported: DefaultsValueModel<Bool>
    @State private var openMarkdown: DefaultsValueModel<Bool>

    /// Creates the file-opening settings section backed by the supplied defaults store and settings catalog.
    public init(
        defaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog
    ) {
        _fileDrop = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.fileDropDefaultBehavior))
        _preferredEditor = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.preferredEditor))
        _fileExtensionOpeners = State(initialValue: FileExtensionOpenersValueModel(store: defaultsStore))
        _openSupported = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.openSupportedFilesInCmux))
        _openMarkdown = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.openMarkdownInCmuxViewer))
    }

    private static let columnWidth: CGFloat = 196

    /// The SwiftUI content for the file-opening settings section.
    public var body: some View {
        Group {
            SettingsSectionHeader(
                String(localized: "settings.section.fileOpening", defaultValue: "File Opening"),
                section: .fileOpening
            )
            .accessibilityIdentifier("SettingsFileOpeningSection")

            SettingsCard {
                SettingsCardRow(
                    configurationReview: .settingsOnly,
                    searchAnchorID: "setting:fileOpening:file-drops",
                    String(localized: "settings.app.fileDrop.defaultBehavior", defaultValue: "File Drops"),
                    subtitle: fileDropSubtitle(fileDrop.current),
                    controlWidth: Self.columnWidth
                ) {
                    Picker("", selection: Binding(get: { fileDrop.current }, set: { fileDrop.set($0) })) {
                        Text(String(localized: "settings.app.fileDrop.defaultBehavior.text", defaultValue: "Drop path text"))
                            .tag(FileDropDefaultBehavior.text)
                        Text(String(localized: "settings.app.fileDrop.defaultBehavior.preview", defaultValue: "Open file preview"))
                            .tag(FileDropDefaultBehavior.preview)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                SettingsCardDivider()

                SettingsCardRow(
                    configurationReview: .json("app.preferredEditor"),
                    String(localized: "settings.app.preferredEditor", defaultValue: "Open Files With"),
                    subtitle: String(localized: "settings.app.preferredEditor.subtitle", defaultValue: "Command used when an extension is set to Preferred Editor, or when Cmd-click file previews are disabled or a file is unsupported. Leave empty for system default.")
                ) {
                    TextField(
                        String(localized: "settings.app.preferredEditor.placeholder", defaultValue: "e.g. code, zed, subl"),
                        text: Binding(get: { preferredEditor.current }, set: { preferredEditor.set($0) })
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                }

                SettingsCardDivider()

                FileExtensionOpenersEditor(
                    openers: Binding(
                        get: { fileExtensionOpeners.current },
                        set: { fileExtensionOpeners.set($0) }
                    )
                )

                SettingsCardDivider()

                SettingsCardRow(
                    configurationReview: .json("app.openSupportedFilesInCmux"),
                    String(localized: "settings.app.openSupportedFilesInCmux", defaultValue: "Open Supported Files in cmux"),
                    subtitle: String(localized: "settings.app.openSupportedFilesInCmux.subtitle", defaultValue: "Cmd-clicking readable files opens text, code, PDFs, images, audio, video, and Quick Look previews in cmux.")
                ) {
                    Toggle("", isOn: Binding(get: { openSupported.current }, set: { openSupported.set($0) }))
                        .labelsHidden()
                        .controlSize(.small)
                }

                SettingsCardDivider()

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
        }
    }

    private func fileDropSubtitle(_ behavior: FileDropDefaultBehavior) -> String {
        switch behavior {
        case .text:
            return String(
                localized: "settings.app.fileDrop.defaultBehavior.text.subtitle",
                defaultValue: "Over terminals and editors, dragging files inserts shell-escaped paths. Hold Shift to open a file preview or split."
            )
        case .preview:
            return String(
                localized: "settings.app.fileDrop.defaultBehavior.preview.subtitle",
                defaultValue: "Dragging files opens previews or split panes. Hold Shift over terminals and editors to insert path text."
            )
        }
    }
}

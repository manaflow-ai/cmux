import CmuxSettings
import SwiftUI

@MainActor
public struct FileExtensionOpenersEditor: View {
    @Binding private var openers: [String: FileExtensionOpenBehavior]
    @State private var draftExtension = ""

    public init(openers: Binding<[String: FileExtensionOpenBehavior]>) {
        self._openers = openers
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCardRow(
                configurationReview: .json("app.fileExtensionOpeners"),
                String(localized: "settings.app.fileExtensionOpeners", defaultValue: "File Extension Openers"),
                subtitle: String(localized: "settings.app.fileExtensionOpeners.subtitle", defaultValue: "Choose how Cmd-click opens specific file extensions. HTML opens in the cmux browser by default.")
            ) {
                HStack(spacing: 6) {
                    TextField(
                        String(localized: "settings.app.fileExtensionOpeners.addPlaceholder", defaultValue: "html"),
                        text: $draftExtension
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 78)

                    Button {
                        addDraftExtension()
                    } label: {
                        Label(String(localized: "settings.app.fileExtensionOpeners.add", defaultValue: "Add"), systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(normalizedDraftExtension == nil)
                }
            }

            if sortedExtensions.isEmpty {
                SettingsCardDivider()
                SettingsCardNote(String(localized: "settings.app.fileExtensionOpeners.empty", defaultValue: "No extension overrides. Cmd-click falls back to the supported-file and Markdown settings."))
            } else {
                ForEach(sortedExtensions, id: \.self) { fileExtension in
                    SettingsCardDivider()
                    openerRow(fileExtension)
                }
            }
        }
    }

    private var sortedExtensions: [String] {
        openers.keys.sorted { lhs, rhs in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private var normalizedDraftExtension: String? {
        FileExtensionOpenBehavior.normalizedExtension(draftExtension)
    }

    private func openerRow(_ fileExtension: String) -> some View {
        HStack(spacing: 12) {
            Text(".\(fileExtension)")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .frame(width: 86, alignment: .leading)
                .lineLimit(1)

            Picker(
                "",
                selection: Binding(
                    get: { openers[fileExtension] ?? .automatic },
                    set: { setBehavior($0, for: fileExtension) }
                )
            ) {
                ForEach(FileExtensionOpenBehavior.allCases) { behavior in
                    Text(displayName(for: behavior)).tag(behavior)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 170, alignment: .trailing)

            Button {
                remove(fileExtension)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .help(String(localized: "settings.app.fileExtensionOpeners.remove", defaultValue: "Remove extension opener"))
            .accessibilityLabel(String(localized: "settings.app.fileExtensionOpeners.remove", defaultValue: "Remove extension opener"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addDraftExtension() {
        guard let normalized = normalizedDraftExtension else { return }
        var next = normalizedOpeners(openers)
        if next[normalized] == nil {
            next[normalized] = .cmuxPreview
        }
        openers = next
        draftExtension = ""
    }

    private func setBehavior(_ behavior: FileExtensionOpenBehavior, for fileExtension: String) {
        var next = normalizedOpeners(openers)
        next[fileExtension] = behavior
        openers = next
    }

    private func remove(_ fileExtension: String) {
        var next = normalizedOpeners(openers)
        next.removeValue(forKey: fileExtension)
        openers = next
    }

    private func normalizedOpeners(_ value: [String: FileExtensionOpenBehavior]) -> [String: FileExtensionOpenBehavior] {
        var normalized: [String: FileExtensionOpenBehavior] = [:]
        for (rawExtension, behavior) in value {
            guard let normalizedExtension = FileExtensionOpenBehavior.normalizedExtension(rawExtension) else { continue }
            normalized[normalizedExtension] = behavior
        }
        return normalized
    }

    private func displayName(for behavior: FileExtensionOpenBehavior) -> String {
        switch behavior {
        case .automatic:
            return String(localized: "settings.app.fileExtensionOpeners.behavior.automatic", defaultValue: "Automatic")
        case .cmuxPreview:
            return String(localized: "settings.app.fileExtensionOpeners.behavior.cmuxPreview", defaultValue: "cmux Preview")
        case .markdownViewer:
            return String(localized: "settings.app.fileExtensionOpeners.behavior.markdownViewer", defaultValue: "Markdown Viewer")
        case .cmuxBrowser:
            return String(localized: "settings.app.fileExtensionOpeners.behavior.cmuxBrowser", defaultValue: "cmux Browser")
        case .preferredEditor:
            return String(localized: "settings.app.fileExtensionOpeners.behavior.preferredEditor", defaultValue: "Preferred Editor")
        case .systemDefault:
            return String(localized: "settings.app.fileExtensionOpeners.behavior.systemDefault", defaultValue: "System Default")
        }
    }
}

import AppKit
import CmuxSettings
import SwiftUI

/// **cmux.json** section — live editor + reload + save.
@MainActor
public struct SettingsJSONSection: View {
    private let jsonStore: JSONConfigStore
    private let hostActions: SettingsHostActions?

    @State private var draft: String = ""
    @State private var loaded: Bool = false
    @State private var statusMessage: String?
    @State private var statusIsError: Bool = false

    public init(jsonStore: JSONConfigStore, hostActions: SettingsHostActions? = nil) {
        self.jsonStore = jsonStore
        self.hostActions = hostActions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionHeader("cmux.json")
            SettingsCard {
                SettingsCardRow(configurationReview: .action, "Config File",
                    subtitle: jsonStore.fileURL.path) {
                    HStack(spacing: 6) {
                        if let hostActions {
                            Button("Open in External Editor") {
                                hostActions.openConfigInExternalEditor()
                            }
                            .controlSize(.small)
                        }
                        Button("Reload") { reloadFromDisk() }
                            .controlSize(.small)
                        Button("Save") { saveToDisk() }
                            .keyboardShortcut("s", modifiers: .command)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
                if let statusMessage {
                    SettingsCardDivider()
                    HStack {
                        Label(statusMessage, systemImage: statusIsError ? "exclamationmark.triangle" : "checkmark.circle")
                            .foregroundStyle(statusIsError ? Color.red : Color.green)
                            .font(.caption)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
                SettingsCardDivider()
                TextEditor(text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 320)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(NSColor.textBackgroundColor))
            }
        }
        .task {
            if !loaded {
                reloadFromDisk()
                loaded = true
            }
        }
    }

    private func reloadFromDisk() {
        if let data = try? Data(contentsOf: jsonStore.fileURL) {
            draft = String(decoding: data, as: UTF8.self)
            statusMessage = "Loaded \(data.count) bytes"
            statusIsError = false
        } else {
            draft = ""
            statusMessage = "File is empty or missing — writes will create it."
            statusIsError = false
        }
    }

    private func saveToDisk() {
        do {
            let parent = jsonStore.fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try Data(draft.utf8).write(to: jsonStore.fileURL, options: .atomic)
            statusMessage = "Saved to disk"
            statusIsError = false
        } catch {
            statusMessage = error.localizedDescription
            statusIsError = true
        }
    }
}

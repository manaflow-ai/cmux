import CmuxSettings
import SwiftUI

/// SwiftUI view for the **cmux.json** section.
///
/// A live editor against the cmux JSON config file. Reads through
/// ``JSONConfigStore``'s underlying file URL, writes back via
/// `Data.write(to:options:)`. The cmux file watcher picks up the saved
/// change and propagates it through every observer in the app.
///
/// This is intentionally a small editor — the goal is to let advanced
/// users hand-edit JSONC, not to replicate Xcode's editor. JSONC
/// comments and trailing commas are tolerated on save because the
/// store's ``JSONCSanitizer`` strips them on read.
public struct SettingsJSONSection: View {
    private let jsonStore: JSONConfigStore

    @State private var draft: String = ""
    @State private var loaded: Bool = false
    @State private var statusMessage: String?
    @State private var statusIsError: Bool = false

    public init(jsonStore: JSONConfigStore) {
        self.jsonStore = jsonStore
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(jsonStore.fileURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button("Reload from disk") { reloadFromDisk() }
                Button("Save") { saveToDisk() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            if let statusMessage {
                Label(statusMessage, systemImage: statusIsError ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(statusIsError ? Color.red : Color.green)
                    .font(.caption)
            }
            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 320)
                .padding(4)
                .background(Color(NSColor.textBackgroundColor))
                .border(Color(NSColor.separatorColor))
        }
        .padding()
        .task {
            if !loaded {
                reloadFromDisk()
                loaded = true
            }
        }
    }

    private func reloadFromDisk() {
        do {
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

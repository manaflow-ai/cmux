import AppKit
import CmuxSettings
import SwiftUI

/// Search row above the shortcut list: a text field, plus a detector button
/// that captures the next keystrokes and filters the list to the actions they
/// run. Laid out in the same columns as ``ShortcutListRowView`` so the detector
/// lines up with the recorders and the clear button with the unbind buttons.
struct ShortcutListSearchBar: View {
    @Binding var query: ShortcutListSearchQuery
    /// Whether a binding is a chord starting with the stroke, so the detector
    /// waits for the second stroke.
    let hasChord: (ShortcutStroke) -> Bool

    var body: some View {
        HStack(spacing: 12) {
            TextField(
                String(localized: "settings.shortcuts.search.placeholder", defaultValue: "Search shortcuts"),
                text: $query.text
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("SettingsShortcutSearchField")

            ShortcutDetectorView(
                placeholder: query.keys.map { shortcutDisplayString($0, numbered: false) }
                    ?? String(localized: "settings.shortcuts.detector.idle", defaultValue: "Record Keys"),
                awaitsSecondStroke: hasChord,
                onKeys: { query.keys = $0 }
            )
            .frame(width: 160)
            .help(String(
                localized: "settings.shortcuts.detector.help",
                defaultValue: "Press keys to see which shortcut uses them"
            ))
            .accessibilityLabel(String(
                localized: "settings.shortcuts.detector.accessibilityLabel",
                defaultValue: "Find shortcut by keys"
            ))
            .accessibilityIdentifier("SettingsShortcutDetector")

            Button {
                query = ShortcutListSearchQuery()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.medium)
            }
            .buttonStyle(.borderless)
            .disabled(query.isEmpty)
            .help(String(localized: "settings.shortcuts.search.clear", defaultValue: "Clear search"))
            .accessibilityLabel(String(localized: "settings.shortcuts.search.clear", defaultValue: "Clear search"))
            .accessibilityIdentifier("SettingsShortcutSearchClearButton")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

/// The detector: a ``RecorderHostButton`` that reports keys instead of binding
/// them. It accepts bare keys (content-scoped shortcuts use them) and waits for
/// a second stroke only when some chord starts with the first.
private struct ShortcutDetectorView: NSViewRepresentable {
    let placeholder: String
    let awaitsSecondStroke: (ShortcutStroke) -> Bool
    let onKeys: (StoredShortcut) -> Void

    func makeNSView(context: Context) -> RecorderHostButton {
        let button = RecorderHostButton()
        configure(button)
        return button
    }

    func updateNSView(_ nsView: RecorderHostButton, context: Context) {
        configure(nsView)
    }

    static func dismantleNSView(_ nsView: RecorderHostButton, coordinator: Void) {
        nsView.cancelRecordingIfActive()
    }

    private func configure(_ button: RecorderHostButton) {
        let onKeys = onKeys
        button.placeholder = placeholder
        button.recordingPrompt = String(localized: "settings.shortcuts.detector.prompt", defaultValue: "Press keys…")
        button.firstStrokeRequiresModifier = false
        button.awaitsSecondStroke = awaitsSecondStroke
        button.onFirstStroke = { onKeys(StoredShortcut(first: $0)) }
        button.onStroke = { onKeys(StoredShortcut(first: $0)) }
        button.onChord = onKeys
        button.refreshTitle()
    }
}

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
    /// Bumped by Clear so an armed detector disarms.
    @State private var clearCount = 0

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(
                    String(localized: "settings.shortcuts.search.placeholder", defaultValue: "Search shortcuts"),
                    text: $query.text
                )
                .textFieldStyle(.plain)
                .accessibilityLabel(String(
                    localized: "settings.shortcuts.search.placeholder",
                    defaultValue: "Search shortcuts"
                ))
                .accessibilityIdentifier("SettingsShortcutSearchField")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            }

            ShortcutDetectorView(
                placeholder: query.keys.map { shortcutDisplayString($0, numbered: false) }
                    ?? String(localized: "settings.shortcuts.detector.idle", defaultValue: "Detect Shortcut"),
                awaitsSecondStroke: hasChord,
                clearCount: clearCount,
                onKeys: { keys in
                    query.keys = keys
                    query.detection += 1
                }
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
            .accessibilityValue(query.keys.map { shortcutDisplayString($0, numbered: false) } ?? String(
                localized: "settings.shortcuts.detector.prompt",
                defaultValue: "Listening…"
            ))
            .accessibilityIdentifier("SettingsShortcutDetector")

            Button {
                query = ShortcutListSearchQuery()
                clearCount += 1
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.medium)
            }
            .buttonStyle(.borderless)
            .disabled(query.isEmpty && !RecorderHostButton.isActivelyRecording)
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
    /// Changes when the search is cleared; an armed detector then disarms.
    let clearCount: Int
    let onKeys: (StoredShortcut) -> Void

    final class Coordinator {
        var clearCount: Int

        init(clearCount: Int) {
            self.clearCount = clearCount
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(clearCount: clearCount)
    }

    func makeNSView(context: Context) -> RecorderHostButton {
        let button = RecorderHostButton()
        configure(button)
        return button
    }

    func updateNSView(_ nsView: RecorderHostButton, context: Context) {
        if context.coordinator.clearCount != clearCount {
            context.coordinator.clearCount = clearCount
            nsView.cancelRecordingIfActive()
        }
        configure(nsView)
    }

    static func dismantleNSView(_ nsView: RecorderHostButton, coordinator: Coordinator) {
        nsView.cancelRecordingIfActive()
    }

    private func configure(_ button: RecorderHostButton) {
        let onKeys = onKeys
        button.placeholder = placeholder
        button.recordingPrompt = String(localized: "settings.shortcuts.detector.prompt", defaultValue: "Listening…")
        button.restingImage = Self.symbol("keyboard", for: button)
        button.recordingImage = Self.symbol("keyboard.badge.ellipsis", for: button)
        button.recordingTintColor = .controlAccentColor
        button.firstStrokeRequiresModifier = false
        button.startsRecordingOnFocus = false
        button.awaitsSecondStroke = awaitsSecondStroke
        button.onFirstStroke = { onKeys(StoredShortcut(first: $0)) }
        button.onStroke = { onKeys(StoredShortcut(first: $0)) }
        button.onChord = onKeys
        button.refreshTitle()
    }

    /// A symbol sized to the button's title font so the two share a center line.
    private static func symbol(_ name: String, for button: RecorderHostButton) -> NSImage? {
        let pointSize = button.font?.pointSize ?? NSFont.systemFontSize
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular, scale: .small))
    }
}

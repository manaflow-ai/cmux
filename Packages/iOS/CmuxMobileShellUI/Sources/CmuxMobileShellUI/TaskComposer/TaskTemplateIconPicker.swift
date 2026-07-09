#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct TaskTemplateIconPicker: View {
    @Binding var selection: String
    @State private var emojiInput: String

    init(selection: Binding<String>) {
        self._selection = selection
        // Show an existing custom-emoji icon in the emoji field so reopening
        // the editor reflects the current selection.
        let current = selection.wrappedValue
        self._emojiInput = State(initialValue: Self.gridValues.contains(current) ? "" : current)
    }

    /// Brand icons first (proper nouns, not localized), then SF Symbols.
    private static let agentValues = [
        "agent:claude",
        "agent:codex",
        "agent:opencode",
    ]

    private static let symbols = [
        "terminal",
        "hammer",
        "wrench.and.screwdriver",
        "globe",
        "folder",
        "bolt",
        "testtube.2",
        "ladybug",
        "doc.text",
        "shippingbox",
    ]

    private static let gridValues = agentValues + symbols

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                ForEach(Self.gridValues, id: \.self) { symbol in
                    iconButton(value: symbol)
                }
            }
            TextField(
                L10n.string("mobile.taskComposer.template.iconEmoji", defaultValue: "Custom emoji"),
                text: $emojiInput
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: emojiInput) { _, value in
                guard let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first else { return }
                let emoji = String(first)
                selection = emoji
                if emojiInput != emoji {
                    emojiInput = emoji
                }
            }
        }
    }

    @ViewBuilder
    private func iconButton(value: String) -> some View {
        let isSelected = selection == value
        Button {
            selection = value
        } label: {
            TaskTemplateIcon(value: value)
                .frame(width: 36, height: 36)
                .background(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: Circle())
                .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.accessibilityName(for: value))
    }

    private static func accessibilityName(for value: String) -> String {
        switch value {
        case "agent:claude": return "Claude"
        case "agent:codex": return "Codex"
        case "agent:opencode": return "OpenCode"
        default: return value
        }
    }
}
#endif

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
        self._emojiInput = State(initialValue: Self.customEmojiInput(for: selection.wrappedValue))
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
            emojiInput = Self.customEmojiInput(for: value)
        } label: {
            TaskTemplateIcon(value: value)
                .frame(width: 36, height: 36)
                .background(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: Circle())
                .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(Self.accessibilityName(for: value))
        .accessibilityHint(
            L10n.string(
                "mobile.taskComposer.template.icon.accessibilityHint",
                defaultValue: "Selects this icon for the template."
            )
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    static func customEmojiInput(for selection: String) -> String {
        Self.gridValues.contains(selection) ? "" : selection
    }

    private static func accessibilityName(for value: String) -> String {
        switch value {
        case "agent:claude":
            return L10n.string("mobile.taskComposer.template.seed.claude", defaultValue: "Claude")
        case "agent:codex":
            return L10n.string("mobile.taskComposer.template.seed.codex", defaultValue: "Codex")
        case "agent:opencode":
            return L10n.string("mobile.taskComposer.template.seed.opencode", defaultValue: "OpenCode")
        case "terminal":
            return L10n.string("mobile.taskComposer.template.icon.terminal", defaultValue: "Terminal")
        case "hammer":
            return L10n.string("mobile.taskComposer.template.icon.hammer", defaultValue: "Hammer")
        case "wrench.and.screwdriver":
            return L10n.string("mobile.taskComposer.template.icon.tools", defaultValue: "Tools")
        case "globe":
            return L10n.string("mobile.taskComposer.template.icon.globe", defaultValue: "Globe")
        case "folder":
            return L10n.string("mobile.taskComposer.template.icon.folder", defaultValue: "Folder")
        case "bolt":
            return L10n.string("mobile.taskComposer.template.icon.bolt", defaultValue: "Bolt")
        case "testtube.2":
            return L10n.string("mobile.taskComposer.template.icon.test", defaultValue: "Test")
        case "ladybug":
            return L10n.string("mobile.taskComposer.template.icon.bug", defaultValue: "Bug")
        case "doc.text":
            return L10n.string("mobile.taskComposer.template.icon.document", defaultValue: "Document")
        case "shippingbox":
            return L10n.string("mobile.taskComposer.template.icon.package", defaultValue: "Package")
        default:
            return value
        }
    }
}
#endif

#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct TaskTemplateIconPicker: View {
    @Binding var selection: String
    @State private var emojiInput = ""

    private static let symbols = [
        "brain.head.profile",
        "sparkles",
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                ForEach(Self.symbols, id: \.self) { symbol in
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
            taskTemplateIcon(value)
                .frame(width: 36, height: 36)
                .background(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: Circle())
                .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value)
    }
}

@ViewBuilder
func taskTemplateIcon(_ value: String) -> some View {
    switch MacAvatarIcon.resolve(custom: value, defaultSymbol: "terminal") {
    case .symbol(let name):
        Image(systemName: name)
            .accessibilityHidden(true)
    case .emoji(let emoji):
        Text(emoji)
            .accessibilityHidden(true)
    }
}
#endif

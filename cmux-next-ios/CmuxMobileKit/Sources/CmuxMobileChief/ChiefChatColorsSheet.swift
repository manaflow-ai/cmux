#if os(iOS)
import CmuxConversationCore
import CmuxConversationUI
import SwiftUI
import UIKit

/// Chat Colors…: this chat's bubble and text colours, mine and theirs (the Mac's Chat Colors
/// panel, with its swatches). The chat under the sheet shows each pick as it is made.
struct ChiefChatColorsSheet: View {
    let key: String
    @Environment(\.dismiss) private var dismiss
    private let store = ChiefChatColors.shared

    var body: some View {
        let colors = store.colors(for: key)
        NavigationStack {
            Form {
                Section {
                    swatchRow(String(localized: "mobile.chief.colors.bubble", defaultValue: "Bubble", bundle: .module),
                              \.sent, swatches: ConversationBubbleColors.sentSwatches, colors: colors, id: "sent")
                    textRow(\.sentText, colors: colors, id: "sentText")
                } header: {
                    Text(String(localized: "mobile.chief.colors.mine", defaultValue: "My Messages", bundle: .module))
                }
                Section {
                    swatchRow(String(localized: "mobile.chief.colors.bubble", defaultValue: "Bubble", bundle: .module),
                              \.received, swatches: ConversationBubbleColors.receivedSwatches, colors: colors, id: "received")
                    textRow(\.receivedText, colors: colors, id: "receivedText")
                } header: {
                    Text(String(localized: "mobile.chief.colors.theirs", defaultValue: "Their Messages", bundle: .module))
                } footer: {
                    Text(String(localized: "mobile.chief.colors.footer", defaultValue: "Only this chat changes, on this iPhone.", bundle: .module))
                }
            }
            .navigationTitle(String(localized: "mobile.chief.colors.title", defaultValue: "Chat Colors", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "mobile.chief.colors.reset", defaultValue: "Reset", bundle: .module)) {
                        store.set(ConversationBubbleColors(), for: key)
                    }
                    .disabled(colors.isEmpty)
                    .accessibilityIdentifier("chief.colors.reset")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done"), systemImage: "checkmark") { dismiss() }
                        .accessibilityIdentifier("chief.colors.done")
                }
            }
        }
        // Its detents are the presenting screen's (`presentChatColors`).
        .accessibilityIdentifier("chief.colors")
    }

    /// Default (the slashed circle) and the Mac's swatches.
    private func swatchRow(_ title: String, _ role: WritableKeyPath<ConversationBubbleColors, ConversationColor?>,
                           swatches: [ConversationColor], colors: ConversationBubbleColors, id: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 8)], alignment: .leading, spacing: 8) {
                swatch(nil, selected: colors[keyPath: role] == nil, id: "\(id).default") { set(role, nil) }
                ForEach(swatches, id: \.hex) { color in
                    swatch(color, selected: colors[keyPath: role] == color, id: "\(id).\(color.hex)") { set(role, color) }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Automatic (white or black, whichever reads on the bubble) or any colour.
    private func textRow(_ role: WritableKeyPath<ConversationBubbleColors, ConversationColor?>,
                         colors: ConversationBubbleColors, id: String) -> some View {
        HStack {
            Text(String(localized: "mobile.chief.colors.text", defaultValue: "Text", bundle: .module))
            Spacer()
            Button(String(localized: "mobile.chief.colors.automatic", defaultValue: "Automatic", bundle: .module)) { set(role, nil) }
                .buttonStyle(.borderless)
                .disabled(colors[keyPath: role] == nil)
                .accessibilityIdentifier("chief.colors.\(id).automatic")
            ColorPicker(String(localized: "mobile.chief.colors.text", defaultValue: "Text", bundle: .module),
                        selection: Binding(get: { Color(uiColor: colors[keyPath: role].map(UIColor.init(chiefColor:)) ?? .label) },
                                           set: { if let picked = ConversationColor(uiColor: UIColor($0)) { set(role, picked) } }),
                        supportsOpacity: false)
                .labelsHidden()
                .accessibilityIdentifier("chief.colors.\(id)")
        }
    }

    private func swatch(_ color: ConversationColor?, selected: Bool, id: String, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            ZStack {
                if let color {
                    Circle().fill(Color(uiColor: UIColor(chiefColor: color)))
                } else {
                    Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
                    Rectangle().fill(Color.secondary).frame(width: 1.5, height: 30).rotationEffect(.degrees(45))
                }
            }
            .frame(width: 30, height: 30)
            .padding(3)
            .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color?.hex ?? String(localized: "mobile.chief.colors.default", defaultValue: "Default", bundle: .module))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("chief.colors.\(id)")
    }

    private func set(_ role: WritableKeyPath<ConversationBubbleColors, ConversationColor?>, _ color: ConversationColor?) {
        store.update(key) { $0[keyPath: role] = color }
    }
}

extension UIColor {
    convenience init(chiefColor color: ConversationColor) {
        self.init(red: color.red, green: color.green, blue: color.blue, alpha: 1)
    }
}

extension ConversationColor {
    /// A picked colour, in sRGB.
    init?(uiColor: UIColor) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        self.init(red: Double(red), green: Double(green), blue: Double(blue))
    }
}
#endif

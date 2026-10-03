import AppKit
import CmuxNextDesign
import CmuxNextSettings
import SwiftUI

/// A small, Settings > Wallpaper style grid. The catalog is intentionally
/// bounded so a machine with a large Desktop Pictures directory stays quick.
struct BackdropPickerCard: View {
    let model: SettingsWindowModel
    private let catalog = BackdropCatalog(systemDirectory: URL(fileURLWithPath: "/System/Library/Desktop Pictures"),
                                          fileManager: .default)

    @ViewBuilder var body: some View {
        if experimentalControlsEnabled,
           let descriptor = SettingsSchema.descriptor(for: BackdropSelectionSetting().configPath) {
            SettingsCard(title: SettingsWindowStrings.backdropPickerTitle) {
            VStack(alignment: .leading, spacing: Metrics.space2) {
                Text(SettingsWindowStrings.backdropPickerHint)
                    .font(SettingsStyle.caption)
                    .foregroundStyle(SettingsStyle.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: Metrics.space2)], spacing: Metrics.space2) {
                    tile(selection: nil, descriptor: descriptor)
                    ForEach(catalog.choices, id: \.self) { selection in
                        tile(selection: selection, descriptor: descriptor)
                    }
                }
            }
            .padding(.horizontal, Metrics.space5)
            .padding(.vertical, Metrics.space3)
            }
        }
    }

    private var experimentalControlsEnabled: Bool {
        SettingsSchema.descriptor(for: ExperimentalAppearanceSetting().configPath).flatMap { model.value($0)?.boolValue } ?? false
    }

    @ViewBuilder
    private func tile(selection: BackdropSelection?, descriptor: SettingDescriptor) -> some View {
        let selected = currentID == (selection?.id ?? "none")
        Button {
            model.set(descriptor, .string(selection?.id ?? "none"))
        } label: {
            VStack(alignment: .leading, spacing: Metrics.space1) {
                thumbnail(selection)
                    .frame(height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.corner, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: SettingsStyle.corner, style: .continuous)
                        .stroke(selected ? SettingsStyle.tint : .clear, lineWidth: 2))
                Text(selection?.title ?? SettingsWindowStrings.backdropNone)
                    .font(SettingsStyle.caption)
                    .foregroundStyle(SettingsStyle.text)
                    .lineLimit(1)
                Text(selection?.attribution ?? SettingsWindowStrings.backdropNone)
                    .font(.system(size: 9))
                    .foregroundStyle(SettingsStyle.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selection?.title ?? SettingsWindowStrings.backdropNone)
    }

    @ViewBuilder
    private func thumbnail(_ selection: BackdropSelection?) -> some View {
        if let image = selection?.image() {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            LinearGradient(colors: [SettingsStyle.card, SettingsStyle.selection], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(Image(systemName: "rectangle.slash").foregroundStyle(SettingsStyle.secondary))
        }
    }

    private var currentID: String {
        guard let descriptor = SettingsSchema.descriptor(for: BackdropSelectionSetting().configPath) else { return "none" }
        return model.value(descriptor)?.stringValue ?? "none"
    }
}

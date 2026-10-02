import CmuxNextDesign
import SwiftUI

/// Search field, All, Changed, then every section with its count and a dot
/// when it holds changes.
struct DebugSettingsSidebar: View {
    @Bindable var model: DebugSettingsModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.space1) {
                HStack(spacing: Metrics.space3) {
                    Image(systemName: "magnifyingglass").foregroundStyle(SettingsStyle.tertiary)
                    TextField(DebugSettingsStrings.searchPlaceholder, text: $model.query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .accessibilityIdentifier("cmux.debugSettings.search")
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(SettingsStyle.tertiary)
                    }
                }
                .padding(.horizontal, Metrics.space4)
                .frame(height: SettingsStyle.rowHeight)
                .background(SettingsStyle.hover, in: RoundedRectangle(cornerRadius: SettingsStyle.corner, style: .continuous))
                .padding(.bottom, Metrics.space4)
                DebugSidebarRow(title: DebugSettingsStrings.all, symbol: "list.bullet", count: model.descriptors.count, changed: 0,
                                isSelected: model.selection == .all && model.query.isEmpty) { select(.all) }
                DebugSidebarRow(title: DebugSettingsStrings.changed, symbol: "pencil.circle", count: model.changedCount, changed: 0,
                                isSelected: model.selection == .changed) { select(.changed) }
                Rectangle().fill(SettingsStyle.separator).frame(height: Metrics.dividerThickness).padding(.vertical, Metrics.space2)
                ForEach(model.sections) { section in
                    DebugSidebarRow(title: section.title, symbol: section.symbol, count: model.count(in: section),
                                    changed: model.changedCount(in: section),
                                    isSelected: model.query.isEmpty && model.selection == .section(section.id)) { select(.section(section.id)) }
                }
            }
            .padding(.horizontal, Metrics.space4)
            .padding(.top, Metrics.titlebarHeight + Metrics.space2)
            .padding(.bottom, Metrics.space4)
        }
        .scrollIndicators(.never)
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
    }

    private func select(_ selection: DebugSettingsSelection) {
        model.query = ""
        model.selection = selection
    }
}

private struct DebugSidebarRow: View {
    let title: String
    let symbol: String
    let count: Int
    let changed: Int
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.space4) {
                Image(systemName: symbol).frame(width: Metrics.iconSize + Metrics.space2)
                    .foregroundStyle(isSelected ? SettingsStyle.text : SettingsStyle.secondary)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
                if changed > 0 {
                    Circle().fill(SettingsStyle.text).frame(width: Metrics.space3, height: Metrics.space3)
                }
                Text("\(count)").font(SettingsStyle.caption).monospacedDigit().foregroundStyle(SettingsStyle.tertiary)
            }
            .padding(.horizontal, Metrics.space4)
            .frame(height: SettingsStyle.rowHeight)
            .background(isSelected ? SettingsStyle.selection : (hovering ? SettingsStyle.hover : .clear),
                        in: RoundedRectangle(cornerRadius: SettingsStyle.corner, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

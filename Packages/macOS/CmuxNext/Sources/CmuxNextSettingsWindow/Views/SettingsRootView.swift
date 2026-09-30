import CmuxNextDesign
import CmuxNextSettings
import SwiftUI

/// Sidebar of sections (with search) and the selected section, or the
/// search results across every section.
struct SettingsRootView: View {
    @Bindable var model: SettingsWindowModel

    var body: some View {
        // Reading the tokens re-renders on a theme change of the window's scope.
        let _ = SettingsTheme.shared.tokens
        HStack(spacing: 0) {
            SettingsSidebar(model: model)
                .frame(width: Metrics.sidebarWidth - Metrics.space6 * 2)
            Rectangle().fill(SettingsStyle.separator).frame(width: Metrics.dividerThickness)
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.space6) {
                    if let error = model.writeError {
                        Text(error).font(SettingsStyle.caption).foregroundStyle(SettingsStyle.danger)
                    }
                    if model.query.isEmpty {
                        Text(model.selection.title).font(SettingsStyle.title).foregroundStyle(SettingsStyle.text)
                        SettingsSectionView(model: model, section: model.selection)
                    } else {
                        SettingsSearchResultsView(model: model)
                    }
                }
                .padding(.horizontal, Metrics.space6 + Metrics.space4)
                .padding(.top, Metrics.titlebarHeight)
                .padding(.bottom, Metrics.space6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .background(SettingsStyle.background)
        .tint(SettingsStyle.tint)
        .foregroundStyle(SettingsStyle.text)
        .font(SettingsStyle.body)
        .controlSize(.small)
    }
}

struct SettingsSidebar: View {
    @Bindable var model: SettingsWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space1) {
            HStack(spacing: Metrics.space3) {
                Image(systemName: "magnifyingglass").foregroundStyle(SettingsStyle.tertiary)
                TextField(SettingsWindowStrings.searchPlaceholder, text: $model.query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("cmux.settings.search")
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(SettingsStyle.tertiary)
                }
            }
            .padding(.horizontal, Metrics.space4)
            .frame(height: SettingsStyle.rowHeight)
            .background(SettingsStyle.hover, in: RoundedRectangle(cornerRadius: SettingsStyle.corner, style: .continuous))
            .padding(.bottom, Metrics.space4)
            ForEach(SettingsSection.allCases) { section in
                SidebarRow(section: section, isSelected: model.query.isEmpty && model.selection == section) {
                    model.query = ""
                    model.selection = section
                }
            }
            Spacer()
        }
        .padding(.horizontal, Metrics.space4)
        .padding(.top, Metrics.titlebarHeight + Metrics.space2)
    }
}

private struct SidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.space4) {
                Image(systemName: section.symbol).frame(width: Metrics.iconSize + Metrics.space2)
                    .foregroundStyle(isSelected ? SettingsStyle.text : SettingsStyle.secondary)
                Text(section.title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.space4)
            .frame(height: SettingsStyle.rowHeight)
            .background(isSelected ? SettingsStyle.selection : (hovering ? SettingsStyle.hover : .clear),
                        in: RoundedRectangle(cornerRadius: SettingsStyle.corner, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("cmux.settings.section.\(section.rawValue)")
    }
}

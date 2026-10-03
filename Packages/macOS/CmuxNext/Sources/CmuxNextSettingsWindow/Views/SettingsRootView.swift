import CmuxNextDesign
import CmuxNextSettings
import SwiftUI

/// Sidebar of sections (with search) and the detail. The Debug Settings
/// tunable `settings.layout` (DEV and NIGHTLY) picks pages (one section at a
/// time, search lists results that jump) or one page (every section, the
/// sidebar follows the scroll, search filters in place); read here, so a
/// change switches live.
struct SettingsRootView: View {
    @Bindable var model: SettingsWindowModel

    var body: some View {
        // Reading the tokens re-renders on a theme change of the window's scope.
        let _ = SettingsTheme.shared.tokens
        let layout = SettingsWindowLayout.tunable.value
        HStack(spacing: 0) {
            SettingsSidebar(model: model, layout: layout)
                .frame(width: Metrics.sidebarWidth - Metrics.space6 * 2)
            Rectangle().fill(SettingsStyle.separator).frame(width: Metrics.dividerThickness)
            SettingsDetailView(model: model, layout: layout)
        }
        .tint(SettingsStyle.tint)
        .foregroundStyle(SettingsStyle.text)
        .font(SettingsStyle.body)
        .controlSize(.small)
    }
}

struct SettingsSidebar: View {
    @Bindable var model: SettingsWindowModel
    let layout: SettingsWindowLayout

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space1) {
            HStack(spacing: Metrics.space3) {
                Image(systemName: "magnifyingglass").foregroundStyle(SettingsStyle.tertiary)
                TextField(SettingsWindowStrings.searchPlaceholder, text: $model.query)
                    .textFieldStyle(.plain)
                    // Return opens the first result on its page.
                    .onSubmit { _ = model.openFirstResult() }
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
            // The one page keeps its section selected while search filters it.
            let showsSelection = layout == .onePage || model.query.isEmpty
            ForEach(SettingsSection.allCases) { section in
                SidebarRow(section: section, isSelected: showsSelection && model.selection == section) {
                    model.select(section, layout: layout)
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

import CmuxNextDesign
import SwiftUI

/// Sidebar (search, All, Changed, sections with counts) and the list of
/// tunables under a toolbar with the exports and resets. The one view that
/// reads the model's theme: every view below gets its colors as a value
/// (`EnvironmentValues.settingsStyle`).
struct DebugSettingsRootView: View {
    @Bindable var model: DebugSettingsModel

    var body: some View {
        let style = SettingsStyle(tokens: model.theme.tokens)
        HStack(spacing: 0) {
            DebugSettingsSidebar(model: model)
                .frame(width: Metrics.sidebarWidth)
            Rectangle().fill(style.separator).frame(width: Metrics.dividerThickness)
            VStack(alignment: .leading, spacing: 0) {
                DebugSettingsToolbar(model: model)
                    .padding(.horizontal, Metrics.space6 + Metrics.space4)
                    .padding(.top, Metrics.titlebarHeight)
                    .padding(.bottom, Metrics.space4)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Metrics.space6) {
                        let groups = model.groupedVisible
                        if groups.isEmpty {
                            Text(model.selection == .changed && model.query.isEmpty ? DebugSettingsStrings.nothingChanged : DebugSettingsStrings.noResults)
                                .foregroundStyle(style.secondary)
                        }
                        ForEach(groups, id: \.section.id) { group in
                            SettingsCard(title: group.section.title) {
                                ForEach(group.rows) { descriptor in
                                    DebugTunableRowView(model: model, descriptor: descriptor)
                                    if descriptor.key != group.rows.last?.key {
                                        Rectangle().fill(style.separator).frame(height: Metrics.dividerThickness)
                                            .padding(.leading, Metrics.space5)
                                    }
                                }
                            }
                        }
                        Text(DebugSettingsStrings.footer).font(SettingsStyle.caption).foregroundStyle(style.tertiary)
                    }
                    .padding(.horizontal, Metrics.space6 + Metrics.space4)
                    .padding(.bottom, Metrics.space6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .thinScrollers()
                }
                .scrollIndicators(.automatic)
                .scrollBounceBehavior(.basedOnSize)
                .scrollEdgeFade()
            }
        }
        .tint(style.tint)
        .foregroundStyle(style.text)
        .font(SettingsStyle.body)
        .controlSize(.small)
        .environment(\.settingsStyle, style)
    }
}

/// Title of the current list, the exports and the resets.
private struct DebugSettingsToolbar: View {
    @Bindable var model: DebugSettingsModel
    @Environment(\.settingsStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.space4) {
                Text(title).font(SettingsStyle.title).lineLimit(1)
                Text(DebugSettingsStrings.count(model.visible.count)).font(SettingsStyle.caption).foregroundStyle(style.secondary)
                Spacer(minLength: 0)
            }
            // Actions on their own row, so a narrow window never truncates them.
            HStack(spacing: Metrics.space3) {
                Button(DebugSettingsStrings.copyJSON) { model.copyJSON() }.buttonStyle(SettingsButtonStyle())
                    .accessibilityIdentifier("cmux.debugSettings.copyJSON")
                Button(DebugSettingsStrings.copySwift) { model.copySwift() }.buttonStyle(SettingsButtonStyle())
                    .accessibilityIdentifier("cmux.debugSettings.copySwift")
                if let section = model.selectedSection {
                    Button(DebugSettingsStrings.resetSection) { model.reset(section: section) }.buttonStyle(SettingsButtonStyle())
                        .disabled(model.changedCount(in: section) == 0)
                }
                Button(DebugSettingsStrings.resetAll) { model.resetAll() }.buttonStyle(SettingsButtonStyle(destructive: true))
                    .disabled(model.changedCount == 0)
                    .accessibilityIdentifier("cmux.debugSettings.resetAll")
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            if let notice = model.notice {
                Text(notice).font(SettingsStyle.caption).foregroundStyle(style.secondary)
            }
        }
    }

    private var title: String {
        if !model.query.trimmingCharacters(in: .whitespaces).isEmpty { return "“\(model.query)”" }
        switch model.selection {
        case .all: return DebugSettingsStrings.all
        case .changed: return DebugSettingsStrings.changed
        case .section: return model.selectedSection?.title ?? DebugSettingsStrings.all
        }
    }
}

import CmuxFoundation
import CMUXProjectModel
import SwiftUI

/// Build Settings tab inside ``ProjectPanelView``.
///
/// Renders the "Levels" view: each row is one setting key, with columns for
/// the resolved value, the target override, and the project value. The
/// adapter does not yet shell out to `xcodebuild -showBuildSettings`, so the
/// Resolved column is computed locally as the first non-empty value in the
/// stack (target → project → empty). The cell whose value won is marked.
struct ProjectBuildSettingsTabView: View {
    @ObservedObject var panel: ProjectPanel
    let model: ProjectModel

    /// Drives keyboard focus into the settings filter field for Cmd+F.
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        let computedRows = rows
        VStack(alignment: .leading, spacing: 0) {
            controlsRow(rowCount: computedRows.count)
            Divider()
            tableView(rows: computedRows)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // `onAppear` covers a find requested before this tab mounted (the panel
        // was still loading, or another tab was active); `onChange` covers a find
        // requested while this tab is already on screen.
        .onAppear { applyPendingFindFocusIfNeeded() }
        .onChange(of: panel.findFocus.request) { _, _ in applyPendingFindFocusIfNeeded() }
        .onChange(of: panel.findFocus.resignToken) { _, _ in
            searchFieldFocused = false
        }
    }

    /// Moves keyboard focus into the filter field when a find request targets
    /// the Build Settings tab, then clears the one-shot request.
    private func applyPendingFindFocusIfNeeded() {
        guard panel.findFocus.request == .buildSettings else { return }
        searchFieldFocused = true
        panel.findFocus.request = nil
    }

    @ViewBuilder
    private func controlsRow(rowCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Target")
                    .cmuxFont(size: 11)
                    .foregroundStyle(.secondary)
                targetPicker
                Spacer(minLength: 4)
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter settings", text: $panel.settingsSearchText)
                    .textFieldStyle(.plain)
                    .cmuxFont(size: 12)
                    .focused($searchFieldFocused)
                Toggle("Customized only", isOn: $panel.settingsCustomizedOnly)
                    .toggleStyle(.checkbox)
                    .cmuxFont(size: 11)
                Text("\(rowCount) settings")
                    .cmuxFont(size: 11)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
    }

    @ViewBuilder
    private var targetPicker: some View {
        if let module = selectedModule ?? model.modules.first {
            Picker(
                "Target",
                selection: Binding(
                    get: { panel.selectedTargetID ?? module.targets.first?.id ?? TargetID(rawValue: "") },
                    set: { panel.selectedTargetID = $0 }
                )
            ) {
                ForEach(module.targets) { target in
                    Text(target.displayName).tag(target.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 160)
        }
    }

    private static let settingColumnWidth: CGFloat = 240
    private static let valueColumnWidth: CGFloat = 170

    @ViewBuilder
    private func tableView(rows computedRows: [BuildSettingRow]) -> some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Spacer().frame(width: 3)
                    columnHeader("Setting", weight: Self.settingColumnWidth, alignment: .leading)
                    columnHeader("Effective", weight: Self.valueColumnWidth, alignment: .leading)
                    columnHeader("Target", weight: Self.valueColumnWidth, alignment: .leading)
                    columnHeader("Project", weight: Self.valueColumnWidth, alignment: .leading)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 14)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.25))
                Divider()
                ForEach(Array(computedRows.enumerated()), id: \.element.key) { index, row in
                    SettingsRow(
                        row: row,
                        settingColumnWidth: Self.settingColumnWidth,
                        valueColumnWidth: Self.valueColumnWidth
                    )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background(
                        index.isMultiple(of: 2)
                            ? Color.primary.opacity(0.025)
                            : Color.clear
                    )
                    .overlay(alignment: .leading) {
                        if row.winner == .target {
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(width: 3)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func columnHeader(_ title: String, weight: CGFloat, alignment: Alignment) -> some View {
        Text(title)
            .cmuxFont(size: 11, weight: .semibold)
            .foregroundStyle(.secondary)
            .frame(width: weight, alignment: alignment)
    }

    private var selectedModule: ProjectModule? {
        if let targetID = panel.selectedTargetID,
           let owner = model.modules.first(where: { $0.target(for: targetID) != nil }) {
            return owner
        }
        return model.modules.first
    }

    private var rows: [BuildSettingRow] {
        guard let module = selectedModule else { return [] }

        let configName = panel.selectedConfigurationName ?? module.configurationNames.first ?? ""
        let projectConfig = module.configurations.first { config in
            config.name == configName && config.scope == .project
        }
        let targetConfig: BuildConfigSummary? = {
            guard let targetID = panel.selectedTargetID else { return nil }
            return module.configurations.first { config in
                if case let .target(id) = config.scope, id == targetID, config.name == configName {
                    return true
                }
                return false
            }
        }()

        var keys: Set<String> = []
        for k in projectConfig?.rawSettings.keys ?? [:].keys { keys.insert(k) }
        for k in targetConfig?.rawSettings.keys ?? [:].keys { keys.insert(k) }

        let filter = panel.settingsSearchText.lowercased()
        let filteredKeys = filter.isEmpty
            ? Array(keys)
            : keys.filter { $0.lowercased().contains(filter) }

        return filteredKeys.sorted().compactMap { key in
            let projectValue = projectConfig?.rawSettings[key]
            let targetValue = targetConfig?.rawSettings[key]
            if panel.settingsCustomizedOnly && targetValue == nil && projectValue == nil {
                return nil
            }
            let resolved = targetValue ?? projectValue ?? ""
            let winner: BuildSettingRow.Winner = {
                if targetValue != nil { return .target }
                if projectValue != nil { return .project }
                return .none
            }()
            return BuildSettingRow(
                key: key,
                resolvedValue: resolved,
                targetValue: targetValue,
                projectValue: projectValue,
                winner: winner
            )
        }
    }
}

private struct BuildSettingRow {
    enum Winner { case target, project, none }

    let key: String
    let resolvedValue: String
    let targetValue: String?
    let projectValue: String?
    let winner: Winner
}

private struct SettingsRow: View {
    let row: BuildSettingRow
    let settingColumnWidth: CGFloat
    let valueColumnWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 3)
            Text(row.key)
                .cmuxFont(size: 11, weight: .medium, design: .monospaced)
                .frame(width: settingColumnWidth, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(row.winner == .none ? Color.secondary : Color.primary)
                .help(row.key)
            valueCell(row.resolvedValue, emphasis: .normal)
                .frame(width: valueColumnWidth, alignment: .leading)
            valueCell(row.targetValue ?? "—", emphasis: row.winner == .target ? .accent : .dim)
                .frame(width: valueColumnWidth, alignment: .leading)
            valueCell(row.projectValue ?? "—", emphasis: row.winner == .project ? .normal : .dim)
                .frame(width: valueColumnWidth, alignment: .leading)
        }
    }

    private enum CellEmphasis { case accent, normal, dim }

    @ViewBuilder
    private func valueCell(_ value: String, emphasis: CellEmphasis) -> some View {
        let style: Color = {
            switch emphasis {
            case .accent: return Color.accentColor
            case .normal: return Color.primary
            case .dim: return Color.secondary
            }
        }()
        Text(value)
            .cmuxFont(size: 11, design: .monospaced)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(value == "—" ? Color.secondary.opacity(0.6) : style)
            .help(value)
    }
}

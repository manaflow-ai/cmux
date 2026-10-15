import AppKit
import CmuxCloud
import CmuxFoundation
import SwiftUI

/// All machines / Project / This machine, with a count per segment, and the
/// project menu on the Project tab.
struct CloudSecretsScopeBar: View {
    @Bindable var model: CloudSecretsSheetModel

    var body: some View {
        HStack(spacing: 10) {
            Picker(selection: $model.tab) {
                ForEach(CloudSecretsSheetModel.Tab.allCases, id: \.self) { tab in
                    Text(segmentTitle(tab)).tag(tab)
                }
            } label: {
                Text(String(localized: "cloudSecrets.scope.label", defaultValue: "Applies to"))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(model.hasModalCard)
            .accessibilityIdentifier("CloudSecretsSheet.scope")

            if model.tab == .project, !model.projectKeys.isEmpty {
                projectMenu
            }
            Spacer(minLength: 0)
        }
    }

    private var projectMenu: some View {
        Menu {
            Button {
                model.projectKey = nil
            } label: {
                checkmarked(String(localized: "cloudSecrets.project.all", defaultValue: "All Projects"), model.projectKey == nil)
            }
            Divider()
            ForEach(model.projectKeys, id: \.self) { key in
                Button {
                    model.projectKey = key
                } label: {
                    checkmarked(CloudSecretsSheetPresentation.shortProjectLabel(key), model.projectKey == key)
                }
                .help(key)
            }
        } label: {
            Text(model.projectKey.map(CloudSecretsSheetPresentation.shortProjectLabel)
                ?? String(localized: "cloudSecrets.project.all", defaultValue: "All Projects"))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.hasModalCard)
        .help(model.projectKey ?? "")
        .accessibilityLabel(String(localized: "cloudSecrets.project.label", defaultValue: "Project"))
        .accessibilityIdentifier("CloudSecretsSheet.project")
    }

    @ViewBuilder
    private func checkmarked(_ title: String, _ isChecked: Bool) -> some View {
        if isChecked {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    /// "Project 2"; a zero count is left off.
    private func segmentTitle(_ tab: CloudSecretsSheetModel.Tab) -> String {
        let title: String
        switch tab {
        case .all:
            title = String(localized: "cloudSecrets.tab.all", defaultValue: "All machines")
        case .project:
            title = String(localized: "cloudSecrets.tab.project", defaultValue: "Project")
        case .machine:
            title = model.isMachineMode
                ? String(localized: "cloudSecrets.tab.thisMachine", defaultValue: "This machine")
                : String(localized: "cloudSecrets.tab.machines", defaultValue: "Machines")
        }
        let count = model.count(for: tab)
        guard count > 0 else { return title }
        return String(
            format: String(localized: "cloudSecrets.tab.count", defaultValue: "%1$@  %2$@"),
            title,
            CloudSecretsSheetPresentation.number(count)
        )
    }
}

/// The tab's secrets. Rows take values and closures only, never the model.
/// Up and Down move the selection; Delete asks to remove it.
struct CloudSecretsList: View {
    @Bindable var model: CloudSecretsSheetModel
    @FocusState private var isFocused: Bool

    /// Past this many rows the list scrolls instead of growing the sheet.
    private static let maxUnscrolledRows = 7

    var body: some View {
        let records = model.visibleRecords
        VStack(alignment: .leading, spacing: 10) {
            if records.isEmpty {
                emptyTab
            } else {
                list(records)
            }
            if model.editor == nil, model.canAdd, !model.availablePresets.isEmpty {
                CloudSecretsPresetChips(presets: model.availablePresets) { model.beginAdd(name: $0) }
            }
        }
    }

    @ViewBuilder
    private func list(_ records: [CloudSecretRecord]) -> some View {
        let rows = VStack(spacing: 0) {
            ForEach(Array(records.enumerated()), id: \.element.sheetID) { index, record in
                if index > 0 { Divider().padding(.leading, 12) }
                row(record)
            }
        }
        Group {
            if records.count > Self.maxUnscrolledRows {
                ScrollView { rows }
                    .frame(height: CGFloat(Self.maxUnscrolledRows) * 40)
            } else {
                rows
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            model.requestRemovalOfSelection() ? .handled : .ignored
        }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            moveSelection(in: records, down: press.key == .downArrow) ? .handled : .ignored
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "cloudSecrets.list.label", defaultValue: "Secrets"))
        .accessibilityIdentifier("CloudSecretsSheet.list")
    }

    private func row(_ record: CloudSecretRecord) -> some View {
        let state = model.rowState(for: record)
        return CloudSecretsRow(
            name: record.name,
            pill: CloudSecretsSheetPresentation.scopePill(record.scope, machineLabels: model.machineLabels),
            scopeDescription: CloudSecretsSheetPresentation.scopeDescription(record.scope, machineLabels: model.machineLabels),
            fingerprint: CloudSecretsSheetPresentation.maskedFingerprint(record.fingerprint),
            updated: CloudSecretsSheetPresentation.updatedLabel(record.updatedAt, now: model.currentDate),
            state: state,
            stateHelp: state.map { CloudSecretsSheetPresentation.stateHelp($0, machineLabels: model.machineLabels) },
            isSelected: model.selectionID == record.sheetID,
            isEnabled: !model.hasModalCard,
            onSelect: {
                model.selectionID = record.sheetID
                isFocused = true
            },
            onReplace: { model.beginReplace(record) },
            onRemove: { model.requestRemoval(record) }
        )
    }

    private func moveSelection(in records: [CloudSecretRecord], down: Bool) -> Bool {
        guard !records.isEmpty, !model.hasModalCard else { return false }
        let current = records.firstIndex { $0.sheetID == model.selectionID }
        let next: Int
        if let current {
            next = min(max(current + (down ? 1 : -1), 0), records.count - 1)
        } else {
            next = down ? 0 : records.count - 1
        }
        model.selectionID = records[next].sheetID
        return true
    }

    private var emptyTab: some View {
        Text(emptyTabText)
            .cmuxFont(size: 12)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .accessibilityIdentifier("CloudSecretsSheet.emptyTab")
    }

    private var emptyTabText: String {
        switch model.tab {
        case .all:
            return String(localized: "cloudSecrets.empty.all", defaultValue: "No secrets for every machine yet. Secrets here reach all your Cloud machines.")
        case .project:
            return String(localized: "cloudSecrets.empty.project", defaultValue: "No project secrets yet. A project secret reaches only machines linked to that project, and wins over one for all machines.")
        case .machine:
            return model.isMachineMode
                ? String(localized: "cloudSecrets.empty.thisMachine", defaultValue: "No secrets only for this machine. A machine secret wins over project and all-machine secrets with the same name.")
                : String(localized: "cloudSecrets.empty.machines", defaultValue: "No machine-only secrets. To add one, open Secrets from a machine’s menu.")
        }
    }
}

/// One stored secret: monospace name, scope pill, the machine state when
/// the sheet is about a machine, and the masked fingerprint with its age.
/// Replace… and Remove appear on hover or selection, and are always in the
/// context menu and the VoiceOver actions.
private struct CloudSecretsRow: View {
    let name: String
    let pill: String?
    let scopeDescription: String
    let fingerprint: String
    let updated: String
    let state: CloudSecretsSheetPresentation.RowState?
    let stateHelp: String?
    let isSelected: Bool
    let isEnabled: Bool
    let onSelect: () -> Void
    let onReplace: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .cmuxFont(size: 12, weight: .medium, design: .monospaced)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if let pill {
                CloudSecretsPill(text: pill, help: scopeDescription)
            }
            Spacer(minLength: 8)
            if let state {
                CloudSecretsStateChip(state: state, help: stateHelp ?? "")
            }
            if showsActions {
                actions
            } else {
                metadata
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.14) : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect() }
        .help(fingerprint + "\n" + updated)
        .contextMenu {
            Button(String(localized: "cloudSecrets.row.replace", defaultValue: "Replace…"), action: onReplace)
            Button(String(localized: "cloudSecrets.row.remove", defaultValue: "Remove…"), action: onRemove)
            Divider()
            Button(String(localized: "cloudSecrets.row.copyName", defaultValue: "Copy Name")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(name, forType: .string)
            }
        }
        .disabled(!isEnabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction(named: String(localized: "cloudSecrets.row.replace", defaultValue: "Replace…"), onReplace)
        .accessibilityAction(named: String(localized: "cloudSecrets.row.remove", defaultValue: "Remove…"), onRemove)
        .accessibilityIdentifier("CloudSecretsSheet.row.\(name)")
    }

    private var showsActions: Bool { isEnabled && (isHovered || isSelected) }

    private var metadata: some View {
        HStack(spacing: 10) {
            Text(fingerprint)
                .cmuxFont(size: 11, design: .monospaced)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
            Text(updated)
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            Button(String(localized: "cloudSecrets.row.replace", defaultValue: "Replace…"), action: onReplace)
                .controlSize(.small)
                .accessibilityIdentifier("CloudSecretsSheet.row.\(name).replace")
            Button(action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(String(localized: "cloudSecrets.row.remove.help", defaultValue: "Remove (Delete)"))
            .accessibilityLabel(String(localized: "cloudSecrets.row.remove", defaultValue: "Remove…"))
            .accessibilityIdentifier("CloudSecretsSheet.row.\(name).remove")
        }
    }

    private var accessibilityText: String {
        var parts = [name, scopeDescription, updated]
        if let state { parts.append(CloudSecretsSheetPresentation.stateTitle(state)) }
        return parts.joined(separator: ", ")
    }
}

/// A quiet capsule naming a project or machine.
struct CloudSecretsPill: View {
    let text: String
    var help: String = ""

    var body: some View {
        Text(text)
            .cmuxFont(size: 10, weight: .medium)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .help(help)
    }
}

/// Current / Out of date / Not on machine / Overridden, in semantic color.
struct CloudSecretsStateChip: View {
    let state: CloudSecretsSheetPresentation.RowState
    let help: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
            Text(CloudSecretsSheetPresentation.stateTitle(state))
                .cmuxFont(size: 10, weight: .medium)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.12)))
        .fixedSize()
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityHint(help)
    }

    private var symbol: String {
        switch state {
        case .machine(.current): return "checkmark"
        case .machine(.stale): return "arrow.triangle.2.circlepath"
        case .machine(.missing): return "arrow.down"
        case .machine(.extra): return "minus"
        case .overridden: return "arrow.turn.down.right"
        }
    }

    private var tint: Color {
        switch state {
        case .machine(.current): return .green
        case .machine(.stale), .machine(.missing): return .orange
        case .machine(.extra), .overridden: return .secondary
        }
    }
}

/// "Quick add" chips that fill in a well-known name. Closures only.
private struct CloudSecretsPresetChips: View {
    let presets: [CloudSecretCatalog.Preset]
    let onPick: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(String(localized: "cloudSecrets.presets.label", defaultValue: "Quick add"))
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize()
            ForEach(presets, id: \.name) { preset in
                Button {
                    onPick(preset.name)
                } label: {
                    Label(preset.label, systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .cmuxFont(size: 11)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .fixedSize()
                .help(String(
                    format: String(localized: "cloudSecrets.presets.help", defaultValue: "Add %1$@, used by %2$@"),
                    preset.name,
                    preset.agents.joined(separator: ", ")
                ))
                .accessibilityLabel(String(
                    format: String(localized: "cloudSecrets.presets.accessibility", defaultValue: "Add %@ key"),
                    preset.label
                ))
                .accessibilityIdentifier("CloudSecretsSheet.preset.\(preset.name)")
            }
            Spacer(minLength: 0)
        }
    }
}

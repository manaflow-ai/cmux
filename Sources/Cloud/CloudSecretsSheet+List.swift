import AppKit
import CmuxCloud
import CmuxFoundation
import SwiftUI

/// All machines / Project / This machine, with a count per segment, and the
/// project menu on the Project tab.
///
/// The bar never overflows the sheet's gutters. It keeps the segments and the
/// project menu on one line when they fit; otherwise the menu moves to its own
/// line under the segments, and as a last resort the segments share the width
/// and truncate. French and Spanish ("Toutes les machines 2", "Todos los
/// proyectos") are the widest catalog strings and take the second layout.
struct CloudSecretsScopeBar: View {
    @Bindable var model: CloudSecretsSheetModel

    var body: some View {
        let showsProjectMenu = model.tab == .project && !model.projectKeys.isEmpty
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                segments.fixedSize()
                if showsProjectMenu { projectMenu.fixedSize() }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    segments.fixedSize()
                    Spacer(minLength: 0)
                }
                if showsProjectMenu { projectMenuRow }
            }
            VStack(alignment: .leading, spacing: 8) {
                segments.frame(maxWidth: .infinity)
                if showsProjectMenu { projectMenuRow }
            }
        }
    }

    private var segments: some View {
        Picker(selection: $model.tab) {
            ForEach(CloudSecretsSheetModel.Tab.allCases, id: \.self) { tab in
                Text(segmentTitle(tab)).tag(tab)
            }
        } label: {
            Text(String(localized: "cloudSecrets.scope.label", defaultValue: "Applies to"))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(model.hasModalCard)
        .accessibilityIdentifier("CloudSecretsSheet.scope")
    }

    /// The menu on its own line: it truncates a long project name instead of
    /// pushing past the sheet's edge.
    private var projectMenuRow: some View {
        HStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                projectMenu.fixedSize()
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
                    checkmarked(model.projectLabel(key), model.projectKey == key)
                }
                .help(key)
            }
        } label: {
            Text(model.projectKey.map { model.projectLabel($0) }
                ?? String(localized: "cloudSecrets.project.all", defaultValue: "All Projects"))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
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

    var body: some View {
        let records = model.visibleRecords
        let needed = model.unsetRequirements
        VStack(alignment: .leading, spacing: 10) {
            if !needed.isEmpty {
                CloudSecretsRequirementList(
                    requirements: needed,
                    projectLabel: model.unsetRequirementsProjectLabel,
                    isEnabled: !model.hasModalCard,
                    onSet: { model.beginSetRequirement($0) }
                )
            }
            if records.isEmpty {
                // The ghost rows already say what this project needs.
                if needed.isEmpty { emptyTab }
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
                    .id(record.sheetID)
            }
        }
        // The sheet's body scrolls; the list keeps its full height inside it.
        rows
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
        let state = CloudSecretsSheetPresentation.visibleChip(model.rowState(for: record))
        let labels = model.machineLabels
        let projects = model.projectDisplayNames
        return CloudSecretsRow(
            name: record.name,
            pill: CloudSecretsSheetPresentation.scopePill(record.scope, machineLabels: labels, projectLabels: projects),
            scopeDescription: CloudSecretsSheetPresentation.scopeDescription(record.scope, machineLabels: labels, projectLabels: projects),
            fingerprint: CloudSecretsSheetPresentation.maskedFingerprint(record.fingerprint),
            updated: CloudSecretsSheetPresentation.updatedLabel(record.updatedAt, now: model.currentDate),
            age: CloudSecretsSheetPresentation.ageLabel(record.updatedAt, now: model.currentDate),
            reservesStateColumn: model.isMachineMode,
            state: state,
            stateHelp: state.map { CloudSecretsSheetPresentation.stateHelp($0, machineLabels: labels) },
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
            return String(localized: "cloudSecrets.empty.all", defaultValue: "No secrets for all machines yet. A secret here reaches every Cloud machine you use.")
        case .project:
            return String(localized: "cloudSecrets.empty.project", defaultValue: "No project secrets yet. A project secret reaches only machines linked to that project, and wins over one for all machines.")
        case .machine:
            return model.isMachineMode
                ? String(localized: "cloudSecrets.empty.thisMachine", defaultValue: "No secrets just for this machine yet. A machine secret wins over a project or all-machines secret with the same name.")
                : String(localized: "cloudSecrets.empty.machines", defaultValue: "No machine-only secrets. To add one, open Secrets from a machine’s menu.")
        }
    }
}

/// Names the window's checkout declares (`.cmux/cloud.json` `env`, devcontainer
/// `secrets`) that are not set for its project: ghost rows in a dashed box, each
/// with Set…, which opens the add card with the name filled in. Closures only.
private struct CloudSecretsRequirementList: View {
    let requirements: [CloudSecretRequirement]
    let projectLabel: String
    let isEnabled: Bool
    let onSet: (CloudSecretRequirement) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(requirements.enumerated()), id: \.element.name) { index, requirement in
                if index > 0 { Divider().padding(.leading, 12) }
                CloudSecretsRequirementRow(
                    name: requirement.name,
                    detail: CloudSecretsSheetPresentation.requirementDetail(projectLabel: projectLabel),
                    help: CloudSecretsSheetPresentation.requirementHelp(requirement),
                    isEnabled: isEnabled,
                    onSet: { onSet(requirement) }
                )
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(
            format: String(localized: "cloudSecrets.requirement.listLabel", defaultValue: "Secrets %@ needs"),
            projectLabel
        ))
        .accessibilityIdentifier("CloudSecretsSheet.requirements")
    }
}

/// A declared name with no value: secondary monospace name, "Needed by … · Not
/// set", and a Set… button that is always shown (it is the row's only action).
private struct CloudSecretsRequirementRow: View {
    let name: String
    let detail: String
    let help: String
    let isEnabled: Bool
    let onSet: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "key")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(name)
                .cmuxFont(size: 12, weight: .medium, design: .monospaced)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Text(detail)
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button(String(localized: "cloudSecrets.requirement.set", defaultValue: "Set\u{2026}"), action: onSet)
                .controlSize(.small)
                .disabled(!isEnabled)
                .accessibilityIdentifier("CloudSecretsSheet.requirement.\(name).set")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([name, detail, help].joined(separator: ", "))
        .accessibilityAction(named: String(localized: "cloudSecrets.requirement.set", defaultValue: "Set\u{2026}"), onSet)
        .accessibilityIdentifier("CloudSecretsSheet.requirement.\(name)")
    }
}

/// One stored secret: monospace name and scope pill, then fixed trailing
/// columns so every row lines up: the machine state (only when it is not
/// current), the masked Value ID, the age, and an action slot. Replace and
/// Remove fill that slot on hover or selection without displacing the
/// metadata, and are always in the context menu and the VoiceOver actions.
private struct CloudSecretsRow: View {
    let name: String
    let pill: String?
    let scopeDescription: String
    let fingerprint: String
    let updated: String
    let age: String
    /// The machine view keeps a state column even on rows without a chip.
    let reservesStateColumn: Bool
    let state: CloudSecretsSheetPresentation.RowState?
    let stateHelp: String?
    let isSelected: Bool
    let isEnabled: Bool
    let onSelect: () -> Void
    let onReplace: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false

    /// Trailing column widths, shared by every row.
    private enum Column {
        static let state: CGFloat = 116
        static let fingerprint: CGFloat = 92
        /// Fits the short relative forms outside English ("il y a 5 min",
        /// "5 мин. назад", "vor 3 Tagen") at 11 pt.
        static let age: CGFloat = 78
        static let actions: CGFloat = 46
    }

    var body: some View {
        interactiveRow
            .disabled(!isEnabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(selectionTraits)
            .accessibilityAction(named: String(localized: "cloudSecrets.row.replace", defaultValue: "Replace…"), onReplace)
            .accessibilityAction(named: String(localized: "cloudSecrets.row.remove", defaultValue: "Remove…"), onRemove)
            .accessibilityIdentifier("CloudSecretsSheet.row.\(name)")
    }

    // The row is split into stages so the type checker never sees one long
    // modifier chain with ternaries in it (it timed out on the combined form).
    private var interactiveRow: some View {
        rowContent
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
            .background(rowBackground)
            .onHover { isHovered = $0 }
            .onTapGesture { onSelect() }
            .help(helpText)
            .contextMenu {
                Button(String(localized: "cloudSecrets.row.replace", defaultValue: "Replace…"), action: onReplace)
                Button(String(localized: "cloudSecrets.row.remove", defaultValue: "Remove…"), action: onRemove)
                Divider()
                Button(String(localized: "cloudSecrets.row.copyName", defaultValue: "Copy Name")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(name, forType: .string)
                }
            }
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.14) }
        if isHovered { return Color.primary.opacity(0.04) }
        return Color.clear
    }

    /// "Value ID •••• 3f9a1c2e …" and the age: what the dots mean, in plain words.
    private var helpText: String {
        String(
            format: String(
                localized: "cloudSecrets.row.valueID.help",
                defaultValue: "Value ID %@. It changes when the value changes; the value itself is never shown."
            ),
            fingerprint
        ) + "\n" + updated
    }

    private var selectionTraits: AccessibilityTraits { isSelected ? .isSelected : [] }

    private var rowContent: some View {
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
            if reservesStateColumn {
                stateColumn
            }
            metadataColumns
            actionSlot
        }
    }

    // Kept apart from `rowContent` so no single expression grows long enough
    // to stall the type checker.
    private var metadataColumns: some View {
        HStack(spacing: 8) {
            Text(fingerprint)
                .cmuxFont(size: 11, design: .monospaced)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: Column.fingerprint, alignment: .trailing)
            Text(age)
                .cmuxFont(size: 11)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: Column.age, alignment: .trailing)
        }
    }

    /// Always laid out, so showing the actions never moves the columns.
    private var actionSlot: some View {
        let visible = showsActions
        return actions
            .frame(width: Column.actions, alignment: .trailing)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }

    @ViewBuilder
    private var stateColumn: some View {
        Group {
            if let state {
                CloudSecretsStateChip(state: state, help: stateHelp ?? "")
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .frame(width: Column.state, alignment: .trailing)
    }

    private var showsActions: Bool { isEnabled && (isHovered || isSelected) }

    private var actions: some View {
        HStack(spacing: 2) {
            Button(action: onReplace) {
                Image(systemName: "square.and.pencil")
                    .frame(width: 20, height: 20)
            }
            .help(String(localized: "cloudSecrets.row.replace.help", defaultValue: "Replace the value"))
            .accessibilityLabel(String(localized: "cloudSecrets.row.replace", defaultValue: "Replace…"))
            .accessibilityIdentifier("CloudSecretsSheet.row.\(name).replace")
            Button(action: onRemove) {
                Image(systemName: "trash")
                    .frame(width: 20, height: 20)
            }
            .help(String(localized: "cloudSecrets.row.remove.help", defaultValue: "Remove (Delete)"))
            .accessibilityLabel(String(localized: "cloudSecrets.row.remove", defaultValue: "Remove…"))
            .accessibilityIdentifier("CloudSecretsSheet.row.\(name).remove")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .font(.system(size: 11, weight: .medium))
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

/// Out of date / Not on machine / Overridden / Syncing…, in semantic color.
/// Syncing is quiet: a delivery in flight is not a problem.
struct CloudSecretsStateChip: View {
    let state: CloudSecretsSheetPresentation.RowState
    let help: String

    var body: some View {
        HStack(spacing: 4) {
            if state == .syncing {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .frame(width: 10, height: 10)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(CloudSecretsSheetPresentation.stateTitle(state))
                .cmuxFont(size: 10, weight: .medium)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.12)))
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
        case .syncing: return "arrow.triangle.2.circlepath"
        }
    }

    private var tint: Color {
        switch state {
        case .machine(.current): return .green
        case .machine(.stale), .machine(.missing): return .orange
        case .machine(.extra), .overridden, .syncing: return .secondary
        }
    }
}

/// "Quick add" chips that fill in a well-known name. Closures only.
private struct CloudSecretsPresetChips: View {
    let presets: [CloudSecretCatalog.Preset]
    let onPick: (String) -> Void

    /// Keeps the row inside the sheet's gutters: every chip when they fit,
    /// otherwise fewer from the end (a longer "Quick add" label in German or
    /// Japanese costs the last chip, never the sheet's edge).
    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: presets.count, through: 1, by: -1)), id: \.self) { count in
                row(Array(presets.prefix(count)))
            }
        }
    }

    private func row(_ shown: [CloudSecretCatalog.Preset]) -> some View {
        HStack(spacing: 6) {
            Text(String(localized: "cloudSecrets.presets.label", defaultValue: "Quick add"))
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize()
            ForEach(shown, id: \.name) { preset in
                chip(preset)
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ preset: CloudSecretCatalog.Preset) -> some View {
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
        .accessibilityLabel(CloudSecretsSheetPresentation.presetAccessibility(preset))
        .accessibilityIdentifier("CloudSecretsSheet.preset.\(preset.name)")
    }
}

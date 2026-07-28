import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

enum WorkspaceMacSelection: Hashable {
    case automatic
    case all
    /// A pairing id for saved app instances, or a bare device id for an
    /// unpaired workspace-only computer.
    case machine(String)
}

extension WorkspaceListView {
    var displayPairedMacsForPicker: [MobilePairedMac] {
        if let store {
            return store.displayPairedMacs
        }
        #if canImport(UIKit) && DEBUG
        if UITestConfig.workspaceListLayoutPreviewEnabled {
            return WorkspaceListLayoutPreviewFixture.displayPairedMacs
        }
        #endif
        return []
    }

    var macSelectionScope: WorkspaceMacSelectionScope {
        return WorkspaceMacSelectionScope(
            selection: macSelection,
            workspaces: workspaces,
            displayPairedMacs: displayPairedMacsForPicker,
            foregroundMacDeviceID: store?.connectedMacDeviceID ?? store?.activeTicket?.macDeviceID,
            aliasesFor: { store?.pairedMacAliasIDs(for: $0) ?? [] }
        )
    }

    var activeFilter: MobileWorkspaceListFilter {
        macSelectionScope.activeFilter(base: filter)
    }

    var visibleMacSelection: WorkspaceMacSelection {
        macSelectionScope.visibleSelection
    }

    var liveMachineSnapshots: WorkspaceMachineSnapshots {
        let scope = macSelectionScope
        return WorkspaceMachineSnapshots(
            workspaces: workspaces,
            filterMachineIDFor: { scope.aliasIndex.deviceRepresentativeID(for: $0) },
            macPickerMachineIDs: scope.machineIDs,
            namesByID: macDisplayNamesByID(),
            buildLabelsByID: macBuildLabelsByID(),
            fallbackName: fallbackMacPickerName
        )
    }

    var fallbackMacPickerName: String {
        L10n.string("mobile.workspaces.macPicker.label", defaultValue: "Computer")
    }

    func macDisplayNamesByID() -> [String: String] {
        var names: [String: String] = [:]
        for workspace in workspaces {
            guard let id = workspace.macDeviceID,
                  let name = workspace.macDisplayName,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            names[id] = name
        }
        for device in store?.deviceTreeDevices ?? [] {
            if let name = device.displayName, !name.isEmpty {
                names[device.deviceId] = name
            }
        }
        for mac in store?.pairedMacs ?? [] {
            names[mac.macDeviceID] = mac.resolvedName
            names[mac.id] = mac.resolvedName
        }
        for mac in displayPairedMacsForPicker {
            names[mac.macDeviceID] = mac.resolvedName
            names[mac.id] = mac.resolvedName
        }
        guard let buildScope = MobileIOSBuildScope.current() else { return names }
        return names.mapValues(buildScope.computerDisplayName)
    }

    func macBuildLabelsByID() -> [String: String] {
        if let store {
            return store.pairedMacBuildLabelsByEntryID()
        }
        return MobileShellComposite.buildLabelsByEntryID(
            for: displayPairedMacsForPicker
        ) { _, _ in nil }
    }

    var filterMenuPresentMachineIDs: [String] {
        let aliasIndex = macSelectionScope.aliasIndex
        var seen = Set<String>()
        var present: [String] = []
        for id in MobileWorkspaceListFilter.machineIDs(in: workspaces) {
            let representativeID = aliasIndex.deviceRepresentativeID(for: id)
            if seen.insert(representativeID).inserted {
                present.append(representativeID)
            }
        }
        return present
    }

    func filterMenuMachines(
        machineSnapshots: WorkspaceMachineSnapshots,
        visibleSelection: WorkspaceMacSelection
    ) -> [WorkspaceFilterMachine] {
        switch visibleSelection {
        case .machine:
            return []
        case .all, .automatic:
            return machineSnapshots.filterMachines
        }
    }

    var canCreateWorkspaceForMacSelection: Bool {
        macSelectionScope.canCreateWorkspace(base: canCreateWorkspace)
    }

    #if os(iOS)
    var canRenderGroupsForSelection: Bool {
        #if DEBUG
        // The store-free layout fixture has no foreground Mac, so the
        // foreground-scope gate can never pass there; render its seeded groups
        // so grouped rows and end-of-group slots are exercised in previews.
        if store == nil, UITestConfig.workspaceListLayoutPreviewEnabled {
            return true
        }
        #endif
        return macSelectionScope.canRenderGroupsForSelection
    }

    func macTitlePickerTitle(machineSnapshots: WorkspaceMachineSnapshots) -> String {
        switch visibleMacSelection {
        case .all, .automatic:
            L10n.string("mobile.workspaces.macPicker.allMacs", defaultValue: "All Computers")
        case .machine(let id):
            machineSnapshots.macPickerTitle(for: id, fallback: fallbackMacPickerName)
        }
    }

    func macTitlePicker(machineSnapshots: WorkspaceMachineSnapshots) -> some View {
        WorkspaceMacTitlePicker(
            value: WorkspaceMacTitlePickerValue(
                title: macTitlePickerTitle(machineSnapshots: machineSnapshots),
                isLoading: macTitlePickerShowsProgress,
                selection: currentMacTitlePickerSelection,
                machines: machineSnapshots.macPickerMachines,
                canAddDevice: showAddDevice != nil,
                labelWidth: 155
            ),
            actions: WorkspaceMacTitlePickerActions(
                select: { _ = handleMacTitlePickerSelection($0) },
                addDevice: showAddDevice
            )
        )
        .equatable()
    }

    var showsDevicesButton: Bool {
        if store != nil {
            return true
        }
        #if DEBUG
        return UITestConfig.workspaceListLayoutPreviewEnabled
        #else
        return false
        #endif
    }
    #else
    var canRenderGroupsForSelection: Bool {
        true
    }
    #endif
}

#if os(iOS)
struct WorkspaceMacTitlePicker: View, Equatable {
    let value: WorkspaceMacTitlePickerValue
    let actions: WorkspaceMacTitlePickerActions

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value == rhs.value
    }

    var body: some View {
        Menu {
            Button {
                actions.select(.all)
            } label: {
                menuRow(
                    title: L10n.string(
                        "mobile.workspaces.macPicker.allMacs",
                        defaultValue: "All Computers"
                    ),
                    subtitle: nil,
                    isSelected: value.selection == .all
                )
            }
            .accessibilityAddTraits(value.selection == .all ? .isSelected : [])
            ForEach(value.machines) { machine in
                let selection = WorkspaceMacSelection.machine(machine.id)
                Button {
                    actions.select(selection)
                } label: {
                    menuRow(
                        title: machine.name,
                        subtitle: machine.buildLabel,
                        isSelected: value.selection == selection
                    )
                }
                .accessibilityAddTraits(value.selection == selection ? .isSelected : [])
            }
            if value.canAddDevice {
                Divider()
                Button(action: { actions.addDevice?() }) {
                    Label(
                        L10n.string("mobile.computers.add", defaultValue: "Add Computer"),
                        systemImage: "plus"
                    )
                }
                .accessibilityIdentifier("MobileWorkspaceMacPickerAdd")
            }
        } label: {
            WorkspaceMacTitlePickerLabel(
                title: value.title,
                isLoading: value.isLoading,
                width: value.labelWidth
            )
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .accessibilityIdentifier("MobileWorkspaceMacPicker")
    }

    /// Menu rows must stay a bare Text/Text/Image tuple: UIMenu bridging reads
    /// the first Text as the title, the second as the subtitle, and the Image
    /// as the item icon. Wrapping them in a stack drops the subtitle entirely.
    @ViewBuilder
    private func menuRow(title: String, subtitle: String?, isSelected: Bool) -> some View {
        Text(title)
        if let subtitle {
            Text(subtitle)
        }
        if isSelected {
            Image(systemName: "checkmark")
        }
    }
}

private struct WorkspaceMacTitlePickerLabel: View {
    let title: String
    let isLoading: Bool
    let width: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Text(title)
                .font(.headline.weight(.bold))
                .lineLimit(1)
                .truncationMode(.tail)
                .allowsTightening(true)
                .minimumScaleFactor(0.75)
                .layoutPriority(1)
            ZStack {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .opacity(isLoading ? 0 : 1)
                ProgressView()
                    .controlSize(.mini)
                    .tint(.primary)
                    .opacity(isLoading ? 1 : 0)
            }
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .frame(width: width, alignment: .center)
        .clipped()
        .contentShape(Rectangle())
    }
}
#endif

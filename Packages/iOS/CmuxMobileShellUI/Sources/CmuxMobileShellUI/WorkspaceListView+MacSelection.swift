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
            // The picker offers only computers reachable under the selected
            // connection method: those are the routes the app will attempt.
            let selectedKind: CmxAttachTransportKind =
                connectionMethodStore?.method == .tailscale ? .tailscale : .iroh
            return store.displayPairedMacs.filter { mac in
                mac.routes.contains { $0.kind == selectedKind }
            }
        }
        #if canImport(UIKit) && DEBUG
        if UITestConfig.workspaceListLayoutPreviewEnabled {
            return WorkspaceListLayoutPreviewView.previewPairedMacs
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
            foregroundInstanceTag: store?.connectedMacInstanceTag,
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
        L10n.string("mobile.workspaces.macPicker.connectionLabel", defaultValue: "Connection")
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
    var canMutateForegroundGroupsForSelection: Bool {
        #if DEBUG
        // The store-free layout fixture has no foreground Mac, so the
        // foreground-mutation gate can never pass there. Allow its isolated
        // reorder harness to exercise grouped rows and end-of-group slots.
        if store == nil, UITestConfig.workspaceListLayoutPreviewEnabled {
            return true
        }
        #endif
        return macSelectionScope.canMutateForegroundGroupsForSelection
    }

    func macTitlePickerTitle(machineSnapshots: WorkspaceMachineSnapshots) -> String {
        switch visibleMacSelection {
        case .all, .automatic:
            L10n.string("mobile.workspaces.macPicker.allConnections", defaultValue: "All Connections")
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
                labelWidth: 155,
                statusLine: connectionChrome.statusLine,
                connectionMethod: connectionMethodStore?.method
            ),
            actions: WorkspaceMacTitlePickerActions(
                select: { _ = handleMacTitlePickerSelection($0) },
                addDevice: showAddDevice,
                selectConnectionMethod: connectionMethodStore.map { store in
                    { store.method = $0 }
                }
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
    var canMutateForegroundGroupsForSelection: Bool {
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
                        "mobile.workspaces.macPicker.allConnections",
                        defaultValue: "All Connections"
                    ),
                    subtitle: nil,
                    isSelected: value.selection == .all
                )
            }
            .accessibilityAddTraits(value.selection == .all ? .isSelected : [])
            .accessibilityIdentifier("MobileWorkspaceMacPickerAll")
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
                .accessibilityIdentifier(machineMenuAccessibilityIdentifier(machine.id))
            }
            if value.canAddDevice {
                Divider()
                Button(action: { actions.addDevice?() }) {
                    Label(
                        L10n.string("mobile.connections.add", defaultValue: "Add Connection"),
                        systemImage: "plus"
                    )
                }
                .accessibilityIdentifier("MobileWorkspaceMacPickerAdd")
            }
            // The same app-wide Connection Method choice as Settings, inline
            // where connections are picked so switching costs no extra chrome.
            if let method = value.connectionMethod,
               let selectMethod = actions.selectConnectionMethod {
                Section(L10n.string(
                    "mobile.settings.connectionMethod",
                    defaultValue: "Connection Method"
                )) {
                    Button {
                        selectMethod(.automatic)
                    } label: {
                        menuRow(
                            title: L10n.string(
                                "mobile.settings.connectionMethod.automatic",
                                defaultValue: "Auto-Connect"
                            ),
                            subtitle: nil,
                            isSelected: method == .automatic
                        )
                    }
                    .accessibilityAddTraits(method == .automatic ? .isSelected : [])
                    .accessibilityIdentifier("MobileWorkspaceMacPickerMethodAutomatic")
                    Button {
                        selectMethod(.tailscale)
                    } label: {
                        menuRow(
                            title: L10n.string(
                                "mobile.settings.connectionMethod.tailscale",
                                defaultValue: "Tailscale Only"
                            ),
                            subtitle: nil,
                            isSelected: method == .tailscale
                        )
                    }
                    .accessibilityAddTraits(method == .tailscale ? .isSelected : [])
                    .accessibilityIdentifier("MobileWorkspaceMacPickerMethodTailscale")
                }
            }
        } label: {
            WorkspaceMacTitlePickerLabel(
                title: value.title,
                isLoading: value.isLoading,
                width: value.labelWidth,
                statusLine: value.statusLine
            )
            // Put the identity and status on the final combined label element.
            // UIKit's toolbar bridge can otherwise omit the outer SwiftUI
            // identifier from the native accessibility tree used by CUA.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(value.title)
            .accessibilityValue(
                value.statusLine.map(WorkspaceConnectionStatusLineView.text) ?? ""
            )
            .accessibilityIdentifier("MobileWorkspaceMacPicker")
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

    private func machineMenuAccessibilityIdentifier(_ id: String) -> String {
        let stableID = id.replacingOccurrences(of: "\u{1F}", with: "-")
        return "MobileWorkspaceMacPickerMachine-\(stableID)"
    }
}

private struct WorkspaceMacTitlePickerLabel: View {
    let title: String
    let isLoading: Bool
    let width: CGFloat
    var statusLine: WorkspaceConnectionStatusLine?

    var body: some View {
        VStack(spacing: 1) {
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
            if let statusLine {
                WorkspaceConnectionStatusLineView(line: statusLine)
            }
        }
        .foregroundStyle(.primary)
        .frame(width: width, alignment: .center)
        .clipped()
        .contentShape(Rectangle())
    }
}
#endif

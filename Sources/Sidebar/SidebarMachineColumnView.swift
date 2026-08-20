import CmuxAppKitSupportUI
import CmuxCore
import CmuxFoundation
import Combine
import SwiftUI

/// Finder-style machines column: the leftmost sidebar column listing places
/// terminals run — this Mac, SSH machines, managed cloud VMs.
///
/// Rows are compact single lines (icon, name, connection dot). In the icon
/// rail (`displayMode == .icons`) rows shrink to just the icon and details
/// move into a dwell hover card. Selecting a machine scopes the workspaces
/// column and creation defaults to it.
struct SidebarMachineColumnView: View {
    private static let machineDragPayloadPrefix = "cmux.sidebar.machine:"

    let displayMode: SidebarColumnDisplayMode

    @EnvironmentObject private var tabManager: TabManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontMagnificationPercent
    @StateObject private var rowSettingsStore = SidebarListRowSettingsStore(
        initialSidebarFontSize: GhosttyConfig.loadForCmux().sidebarFontSize
    )
    @State private var observationRevision: UInt64 = 0
    @State private var isAddingSSHMachine = false
    @State private var sshDestination = ""

    var body: some View {
        let _ = observationRevision
        let machines = tabManager.sidebarCreationContextSnapshots()
        let settings = rowSettingsStore.snapshot

        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(machines) { machine in
                    if let index = machines.firstIndex(where: { $0.id == machine.id }) {
                        machineRow(
                            machine,
                            index: index,
                            count: machines.count,
                            settings: settings
                        )
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear
                .frame(height: SidebarListMetrics.scrollTopInset)
                .allowsHitTesting(false)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(height: SidebarListMetrics.bottomScrimHeight)
                .allowsHitTesting(false)
        }
        .mask {
            SidebarWorkspaceScrollEdgeFadeMask(
                topHeight: SidebarListMetrics.topScrimHeight,
                bottomHeight: SidebarListMetrics.bottomScrimHeight
            )
        }
        .overlay(alignment: .top) {
            WindowDragHandleView()
                .frame(height: WindowChromeMetrics.appTitlebarHeight)
                .background(TitlebarDoubleClickMonitorView())
        }
        .background(Color.clear)
        .modifier(ClearScrollBackground())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("SidebarContextColumn")
        .contextMenu {
            addSSHMachineButton
        }
        .alert(
            String(
                localized: "sidebar.machine.addSSH.title",
                defaultValue: "Add Machine via SSH"
            ),
            isPresented: $isAddingSSHMachine
        ) {
            TextField(
                String(
                    localized: "sidebar.machine.addSSH.placeholder",
                    defaultValue: "Host or user@host"
                ),
                text: $sshDestination
            )
            .accessibilityIdentifier("SidebarAddSSHMachineDestination")

            Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {}
            Button(String(localized: "sidebar.machine.addSSH.confirm", defaultValue: "Add Machine")) {
                _ = tabManager.addSidebarSSHMachine(destination: sshDestination)
            }
            .disabled(!tabManager.canAddSidebarSSHMachine(destination: sshDestination))
        } message: {
            Text(
                String(
                    localized: "sidebar.machine.addSSH.message",
                    defaultValue: "Uses your SSH config. New workspaces and terminal tabs use this machine when it is selected."
                )
            )
        }
        .sidebarWorkspaceObservations(
            ids: tabManager.tabs.map(\.id),
            workspaces: tabManager.tabs,
            debouncedInterval: .milliseconds(40)
        ) { _ in
            observationRevision &+= 1
        }
    }

    // MARK: - Rows

    private func machineRow(
        _ machine: SidebarCreationContextSnapshot,
        index: Int,
        count: Int,
        settings: SidebarTabItemSettingsSnapshot
    ) -> some View {
        let moveUpLabel = String(localized: "contextMenu.moveUp", defaultValue: "Move Up")
        let moveDownLabel = String(localized: "contextMenu.moveDown", defaultValue: "Move Down")
        let attachLabel = String(
            localized: "sidebar.machine.attachCmuxTUI",
            defaultValue: "Attach cmux TUI"
        )

        return Button {
            _ = tabManager.selectSidebarCreationContext(id: machine.id)
        } label: {
            rowLabel(machine, settings: settings)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("SidebarContextRow.\(machine.id)")
        .accessibilityLabel(machine.title)
        .help(displayMode == .icons ? "" : machine.subtitle)
        .overlay {
            SidebarHoverCardAnchor(isEnabled: displayMode == .icons) {
                machineHoverCard(machine)
            }
        }
        .draggable(Self.machineDragPayload(for: machine.id))
        .dropDestination(for: String.self) { payloads, _ in
            guard let payload = payloads.first,
                  let draggedID = Self.machineContextID(from: payload)
            else {
                return false
            }
            return tabManager.reorderSidebarMachineCreationContext(
                id: draggedID,
                toIndex: index
            )
        }
        .onDrop(of: SidebarTabDragPayload.dropContentTypes, isTargeted: nil) { _ in
            moveDraggedWorkspaces(to: machine.id)
        }
        .contextMenu {
            addSSHMachineButton

            if machine.capabilities.contains(.attachRemoteCmuxTUI) {
                Button(attachLabel) {
                    _ = tabManager.attachRemoteCmuxTUI(contextID: machine.id)
                }

                Divider()
            }

            Button(moveUpLabel) {
                _ = tabManager.moveSidebarMachineCreationContext(id: machine.id, by: -1)
            }
            .disabled(index == 0)

            Button(moveDownLabel) {
                _ = tabManager.moveSidebarMachineCreationContext(id: machine.id, by: 1)
            }
            .disabled(index >= count - 1)
        }
        .accessibilityAction(named: Text(moveUpLabel)) {
            _ = tabManager.moveSidebarMachineCreationContext(id: machine.id, by: -1)
        }
        .accessibilityAction(named: Text(moveDownLabel)) {
            _ = tabManager.moveSidebarMachineCreationContext(id: machine.id, by: 1)
        }
    }

    @ViewBuilder
    private func rowLabel(
        _ machine: SidebarCreationContextSnapshot,
        settings: SidebarTabItemSettingsSnapshot
    ) -> some View {
        let palette = SidebarListRowPalette(
            isActive: machine.isSelected,
            colorScheme: colorScheme,
            selectionColorHex: settings.selectionColorHex
        )
        let backgroundStyle = sidebarListRowBackgroundStyle(
            activeTabIndicatorStyle: settings.activeTabIndicatorStyle,
            isActive: machine.isSelected,
            isMultiSelected: false,
            customColorHex: nil,
            colorScheme: colorScheme,
            sidebarSelectionColorHex: settings.selectionColorHex
        )

        Group {
            switch displayMode {
            case .regular:
                HStack(spacing: 7) {
                    machineIcon(machine, palette: palette, pointSize: 13)
                        .frame(width: 18, height: 16)
                    Text(machine.title)
                        .font(rowFont(SidebarListMetrics.titleFontSize, settings: settings))
                        .foregroundColor(Color(nsColor: palette.primary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    connectionDot(machine)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
            case .icons:
                machineIcon(machine, palette: palette, pointSize: 15)
                    .frame(width: 22, height: 20)
                    .overlay(alignment: .bottomTrailing) {
                        connectionDot(machine)
                            .offset(x: 3, y: 2)
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(rowBackgroundColor(backgroundStyle))
        }
        .padding(.horizontal, SidebarListMetrics.rowOuterHorizontalPadding)
        .contentShape(Rectangle())
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.18), value: displayMode)
    }

    private func rowBackgroundColor(_ style: SidebarListRowBackgroundStyle) -> Color {
        guard let color = style.color else { return .clear }
        return Color(nsColor: color).opacity(style.opacity)
    }

    /// This Mac renders the actual hardware icon (like Finder's sidebar);
    /// remote machines use tinted SF Symbols.
    @ViewBuilder
    private func machineIcon(
        _ machine: SidebarCreationContextSnapshot,
        palette: SidebarListRowPalette,
        pointSize: CGFloat
    ) -> some View {
        if machine.kind == .local, let hardwareIcon = NSImage(named: NSImage.computerName) {
            Image(nsImage: hardwareIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: machine.systemImageName)
                .font(.system(size: pointSize, weight: .medium))
                .foregroundColor(Color(nsColor: palette.secondary(0.9)))
        }
    }

    @ViewBuilder
    private func connectionDot(_ machine: SidebarCreationContextSnapshot) -> some View {
        if let state = machine.connectionState, let color = Self.dotColor(for: state) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
        }
    }

    private static func dotColor(for state: WorkspaceRemoteConnectionState) -> Color? {
        switch state {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .orange
        case .error:
            return .red
        case .suspended:
            return .yellow
        case .disconnected:
            return Color.secondary.opacity(0.45)
        }
    }

    private func machineHoverCard(_ machine: SidebarCreationContextSnapshot) -> some View {
        let settings = rowSettingsStore.snapshot
        let palette = SidebarListRowPalette(
            isActive: false,
            colorScheme: colorScheme,
            selectionColorHex: settings.selectionColorHex
        )
        let focusedTitle = machine.focusedWorkspaceID.flatMap { id in
            tabManager.tabs.first(where: { $0.id == id })?.title
        }
        return SidebarHoverCardShell(
            icon: { machineIcon(machine, palette: palette, pointSize: 13) },
            title: machine.title
        ) {
            SidebarHoverCardDetailRow(text: machine.subtitle)
            if let focusedTitle, !focusedTitle.isEmpty {
                SidebarHoverCardDetailRow(
                    text: String(
                        localized: "sidebar.machine.hoverCard.focusedWorkspace",
                        defaultValue: "Focused: \(focusedTitle)"
                    )
                )
            }
        }
    }

    // MARK: - Shared actions

    private var addSSHMachineButton: some View {
        Button(
            String(
                localized: "sidebar.machine.addSSH",
                defaultValue: "Add Machine via SSH…"
            )
        ) {
            sshDestination = ""
            isAddingSSHMachine = true
        }
    }

    private static func machineDragPayload(for contextID: String) -> String {
        machineDragPayloadPrefix + contextID
    }

    private func moveDraggedWorkspaces(to contextID: String) -> Bool {
        guard let draggedID = AppDelegate.shared?
            .sidebarWorkspaceDragRegistry.currentWorkspaceId,
            tabManager.tabs.contains(where: { $0.id == draggedID })
        else {
            return false
        }
        let selectedIDs = tabManager.sidebarSelectedWorkspaceIds
        let movingIDs = selectedIDs.contains(draggedID)
            ? tabManager.tabs.compactMap { selectedIDs.contains($0.id) ? $0.id : nil }
            : [draggedID]
        let moved = tabManager.moveSidebarWorkspaces(
            movingIDs,
            toCreationContextID: contextID
        )
        if moved {
            SidebarDragLifecycleNotification().postClearRequest(
                reason: "workspace_reparented_to_machine"
            )
        }
        return moved
    }

    private static func machineContextID(from payload: String) -> String? {
        guard payload.hasPrefix(machineDragPayloadPrefix) else { return nil }
        let id = String(payload.dropFirst(machineDragPayloadPrefix.count))
        return id.isEmpty ? nil : id
    }

    private func rowFont(
        _ baseSize: CGFloat,
        weight: Font.Weight = .regular,
        settings: SidebarTabItemSettingsSnapshot
    ) -> Font {
        Font.system(
            size: GlobalFontMagnification.scaledSize(
                baseSize * settings.sidebarFontScale,
                percent: globalFontMagnificationPercent
            ),
            weight: weight
        )
    }
}

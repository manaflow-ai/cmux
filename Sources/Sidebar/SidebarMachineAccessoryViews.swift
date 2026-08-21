import CmuxCore
import SwiftUI

/// Machine navigation accessories for the single-sidebar layouts: the same
/// machine registry and selection plumbing as the machines column, rendered
/// as chips, a dropdown, or a bottom dock instead of a second column.
/// Prototype-grade styling: these exist so a layout direction can be picked
/// live; the winner gets polished, the rest deleted.

/// Fades a horizontally scrolling strip at both ends so overflow reads as
/// scrollable instead of clipped.
struct SidebarHorizontalEdgeFadeMask: View {
    var fadeWidth: CGFloat = 14

    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [.clear, .black],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: fadeWidth)
            Rectangle().fill(Color.black)
            LinearGradient(
                colors: [.black, .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: fadeWidth)
        }
    }
}

/// Horizontal chip strip (machines as pills above the workspace list).
struct SidebarMachineChipStrip: View {
    @EnvironmentObject private var tabManager: TabManager
    @State private var observationRevision: UInt64 = 0

    var body: some View {
        let _ = observationRevision
        let machines = tabManager.sidebarCreationContextSnapshots()
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(machines) { machine in
                    Button {
                        _ = tabManager.selectSidebarCreationContext(id: machine.id)
                    } label: {
                        HStack(spacing: 4) {
                            SidebarMachineAccessoryIcon(machine: machine, pointSize: 10)
                            Text(machine.title)
                                .font(.system(size: 11, weight: machine.isSelected ? .semibold : .regular))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    machine.isSelected
                                        ? Color.accentColor.opacity(0.85)
                                        : Color.primary.opacity(0.08)
                                )
                        )
                        .foregroundStyle(machine.isSelected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("SidebarMachineChip.\(machine.id)")
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 30)
        .mask(SidebarHorizontalEdgeFadeMask())
        .sidebarWorkspaceObservations(
            ids: tabManager.tabs.map(\.id),
            workspaces: tabManager.tabs,
            debouncedInterval: .milliseconds(40)
        ) { _ in
            observationRevision &+= 1
        }
    }
}

/// Popup machine picker (VS Code remote-indicator style) above the list.
struct SidebarMachineDropdown: View {
    @EnvironmentObject private var tabManager: TabManager
    @State private var observationRevision: UInt64 = 0

    var body: some View {
        let _ = observationRevision
        let machines = tabManager.sidebarCreationContextSnapshots()
        let selected = machines.first(where: \.isSelected) ?? machines.first

        Menu {
            ForEach(machines) { machine in
                Button {
                    _ = tabManager.selectSidebarCreationContext(id: machine.id)
                } label: {
                    if machine.isSelected {
                        Label(machine.title, systemImage: "checkmark")
                    } else {
                        Text(machine.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let selected {
                    SidebarMachineAccessoryIcon(machine: selected, pointSize: 11)
                    Text(selected.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.07))
                .padding(.horizontal, 6)
        )
        .accessibilityIdentifier("SidebarMachineDropdown")
        .sidebarWorkspaceObservations(
            ids: tabManager.tabs.map(\.id),
            workspaces: tabManager.tabs,
            debouncedInterval: .milliseconds(40)
        ) { _ in
            observationRevision &+= 1
        }
    }
}

/// Arc-profile-style bottom bar: the selected machine reads as a named
/// pill, the others collapse to icons; horizontal scroll with edge fades.
struct SidebarMachineDock: View {
    @EnvironmentObject private var tabManager: TabManager
    @State private var observationRevision: UInt64 = 0

    var body: some View {
        let _ = observationRevision
        let machines = tabManager.sidebarCreationContextSnapshots()
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(machines) { machine in
                        Button {
                            _ = tabManager.selectSidebarCreationContext(id: machine.id)
                        } label: {
                            HStack(spacing: 5) {
                                SidebarMachineAccessoryIcon(machine: machine, pointSize: 11)
                                if machine.isSelected {
                                    Text(machine.title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .lineLimit(1)
                                        .frame(maxWidth: 140, alignment: .leading)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                            .padding(.horizontal, machine.isSelected ? 10 : 7)
                            .padding(.vertical, 5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(
                                        machine.isSelected
                                            ? Color.primary.opacity(0.14)
                                            : Color.clear
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .help(machine.title)
                        .id(machine.id)
                        .accessibilityIdentifier("SidebarMachineDockItem.\(machine.id)")
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 36)
            .mask(SidebarHorizontalEdgeFadeMask())
            .onChange(of: machines.first(where: \.isSelected)?.id) { selectedID in
                guard let selectedID else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            }
        }
        .sidebarWorkspaceObservations(
            ids: tabManager.tabs.map(\.id),
            workspaces: tabManager.tabs,
            debouncedInterval: .milliseconds(40)
        ) { _ in
            observationRevision &+= 1
        }
    }
}

/// Shared machine glyph for the accessories (hardware icon for This Mac).
struct SidebarMachineAccessoryIcon: View {
    let machine: SidebarCreationContextSnapshot
    let pointSize: CGFloat

    var body: some View {
        if machine.kind == .local, let hardwareIcon = NSImage(named: NSImage.computerName) {
            Image(nsImage: hardwareIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: pointSize + 4, height: pointSize + 2)
        } else {
            Image(systemName: machine.systemImageName)
                .font(.system(size: pointSize, weight: .medium))
        }
    }
}

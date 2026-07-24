#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// Immutable hidden-computer row with an offline unhide action.
struct HiddenComputerRow: View {
    let computer: MobileHiddenComputer
    let unhide: @MainActor () async -> Void

    @State private var actionTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 12) {
            avatar
            HStack(spacing: 6) {
                Text(computer.displayName)
                    .font(.headline)
                    .lineLimit(1)
                if computer.instanceTag != nil,
                   let buildLabel = MacBuildChannel().label(
                       bundleID: nil,
                       tag: computer.instanceTag
                   ) {
                    ComputerBuildBadge(label: buildLabel)
                }
            }
            Spacer(minLength: 8)
            Button(action: performUnhide) {
                if actionTask != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Text(L10n.string(
                        "mobile.computers.unhide",
                        defaultValue: "Unhide"
                    ))
                }
            }
            .disabled(actionTask != nil)
            .buttonStyle(.borderless)
            .accessibilityIdentifier("MobileComputerUnhide-\(computer.id)")
        }
        .padding(.vertical, 4)
        .onDisappear {
            actionTask?.cancel()
            actionTask = nil
        }
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(MachineAvatarColors.gradient(
                    customColor: computer.customColor,
                    fallbackIndex: nil,
                    machineID: computer.macDeviceID,
                    fallbackID: computer.id
                ))
                .frame(width: 36, height: 36)
            switch MacAvatarIcon.resolve(
                custom: computer.customIcon,
                defaultSymbol: "desktopcomputer"
            ) {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            case .emoji(let emoji):
                Text(emoji).font(.system(size: 18))
            }
        }
        .accessibilityHidden(true)
    }

    private func performUnhide() {
        guard actionTask == nil else { return }
        actionTask = Task { @MainActor in
            defer { actionTask = nil }
            await unhide()
        }
    }
}

/// Shared localized copy for every Hidden Computers surface so the strings
/// cannot drift between the Computers screen, the disconnected shell, and its
/// empty state.
enum HiddenComputersCopy {
    static var title: String {
        L10n.string("mobile.computers.hidden.title", defaultValue: "Hidden Computers")
    }

    static var footer: String {
        L10n.string(
            "mobile.computers.hidden.footer",
            defaultValue: "Hidden computers stay signed in to your account and are only hidden on this iPhone."
        )
    }
}

/// Shared per-computer row wiring for Hidden Computers lists. Takes immutable
/// snapshots plus closures only; the store stays at the caller's boundary.
struct HiddenComputersRows: View {
    let computers: [MobileHiddenComputer]
    let unhide: @MainActor (MobileHiddenComputer) async -> Void

    var body: some View {
        ForEach(computers) { computer in
            HiddenComputerRow(
                computer: computer,
                unhide: { await unhide(computer) }
            )
        }
    }
}

/// The list-style Hidden Computers section shared by the Computers screen and
/// the disconnected shell.
struct HiddenComputersSection: View {
    let computers: [MobileHiddenComputer]
    let unhide: @MainActor (MobileHiddenComputer) async -> Void

    var body: some View {
        Section {
            HiddenComputersRows(
                computers: computers,
                unhide: unhide
            )
        } header: {
            Text(HiddenComputersCopy.title)
        } footer: {
            Text(HiddenComputersCopy.footer)
        }
    }
}
#endif

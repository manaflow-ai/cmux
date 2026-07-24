#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// Immutable hidden-computer row with offline unhide and legacy recovery actions.
struct HiddenComputerRow: View {
    let computer: MobileHiddenComputer
    let isRecoveringLegacyComputer: Bool
    let unhide: @MainActor () async -> Void
    let recoverLegacyComputer: @MainActor () async -> MobileHiddenComputerRecoveryResult

    @State private var actionTask: Task<Void, Never>?
    @State private var alertMessage: String?

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(computer.displayName)
                    .font(.headline)
                    .lineLimit(1)
                if computer.requiresLegacyRecovery {
                    Text(L10n.string(
                        "mobile.computers.hidden.legacyStatus",
                        defaultValue: "Needs this Mac online once"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button(action: performUnhide) {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Text(L10n.string(
                        "mobile.computers.unhide",
                        defaultValue: "Unhide"
                    ))
                }
            }
            .disabled(isBusy)
            .buttonStyle(.borderless)
            .accessibilityIdentifier("MobileComputerUnhide-\(computer.id)")
        }
        .padding(.vertical, 4)
        .alert(
            L10n.string(
                "mobile.computers.unhideFailedTitle",
                defaultValue: "Couldn't unhide computer"
            ),
            isPresented: alertPresented
        ) {
            Button(L10n.string("mobile.common.ok", defaultValue: "OK"), role: .cancel) {
                alertMessage = nil
            }
        } message: {
            Text(alertMessage ?? "")
        }
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

    private var isBusy: Bool {
        actionTask != nil
            || (computer.requiresLegacyRecovery && isRecoveringLegacyComputer)
    }

    private var alertPresented: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )
    }

    private func performUnhide() {
        guard !isBusy else { return }
        actionTask = Task { @MainActor in
            defer { actionTask = nil }
            if computer.requiresLegacyRecovery {
                let result = await recoverLegacyComputer()
                guard !Task.isCancelled else { return }
                if result == .notFound {
                    alertMessage = L10n.string(
                        "mobile.computers.unhideFailedMessage",
                        defaultValue: "This computer was removed with an older version of cmux. Open cmux on the Mac, make sure it is online and signed in to this account, then try again."
                    )
                }
            } else {
                await unhide()
            }
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
            defaultValue: "Hidden computers stay signed in to your account and are only hidden on this iPhone. A computer removed with an older version of cmux needs its Mac online and signed in once to restore."
        )
    }
}

/// Shared per-computer row wiring for Hidden Computers lists. Takes immutable
/// snapshots plus closures only; the store stays at the caller's boundary.
struct HiddenComputersRows: View {
    let computers: [MobileHiddenComputer]
    let isRecoveringLegacyComputer: Bool
    let unhide: @MainActor (MobileHiddenComputer) async -> Void
    let recoverLegacyComputer: @MainActor (MobileHiddenComputer) async -> MobileHiddenComputerRecoveryResult

    var body: some View {
        ForEach(computers) { computer in
            HiddenComputerRow(
                computer: computer,
                isRecoveringLegacyComputer: isRecoveringLegacyComputer,
                unhide: { await unhide(computer) },
                recoverLegacyComputer: { await recoverLegacyComputer(computer) }
            )
        }
    }
}

/// The list-style Hidden Computers section shared by the Computers screen and
/// the disconnected shell.
struct HiddenComputersSection: View {
    let computers: [MobileHiddenComputer]
    let isRecoveringLegacyComputer: Bool
    let unhide: @MainActor (MobileHiddenComputer) async -> Void
    let recoverLegacyComputer: @MainActor (MobileHiddenComputer) async -> MobileHiddenComputerRecoveryResult

    var body: some View {
        Section {
            HiddenComputersRows(
                computers: computers,
                isRecoveringLegacyComputer: isRecoveringLegacyComputer,
                unhide: unhide,
                recoverLegacyComputer: recoverLegacyComputer
            )
        } header: {
            Text(HiddenComputersCopy.title)
        } footer: {
            Text(HiddenComputersCopy.footer)
        }
    }
}
#endif

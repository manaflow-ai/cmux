#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import Foundation
import SwiftUI

/// Immutable hidden-computer row with offline unhide and legacy recovery actions.
struct HiddenComputerRow: View {
    let computer: MobileHiddenComputer
    let isRecoveringLegacyComputer: Bool
    let unhide: @MainActor () async -> Void
    let recoverLegacyComputer: @MainActor () async -> MobileHiddenComputerRecoveryResult
    let discardLegacyComputer: @MainActor () async -> Void

    @State private var actionTask: Task<Void, Never>?
    @State private var alertMessage: String?

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
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
            if computer.requiresLegacyRecovery {
                Button(
                    L10n.string(
                        "mobile.computers.hidden.removeFromList",
                        defaultValue: "Remove from List"
                    ),
                    role: .destructive,
                    action: performDiscard
                )
                .accessibilityIdentifier("MobileComputerRemoveFromList-\(computer.id)")
            }
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
                if case .notFound(let reason) = result {
                    alertMessage = recoveryFailureMessage(reason: reason)
                }
            } else {
                await unhide()
            }
        }
    }

    private func performDiscard() {
        guard actionTask == nil else { return }
        alertMessage = nil
        actionTask = Task { @MainActor in
            defer { actionTask = nil }
            await discardLegacyComputer()
        }
    }

    private func recoveryFailureMessage(
        reason: MobileHiddenComputerRecoveryFailureReason?
    ) -> String {
        switch reason {
        case .instanceNotLive(let instanceTag):
            guard let buildLabel = MacBuildChannel().label(
                bundleID: nil,
                tag: instanceTag
            ), let appName = recoveryAppDisplayName(for: buildLabel) else {
                return genericRecoveryFailureMessage
            }
            return String(
                format: L10n.string(
                    "mobile.computers.unhideFailed.instanceNotLiveFormat",
                    defaultValue: "This entry is the %1$@ build of %2$@. Open %3$@ on that Mac, sign in to this account, then try again."
                ),
                buildLabel,
                computer.displayName,
                appName
            )
        case .deviceNotFound:
            return L10n.string(
                "mobile.computers.unhideFailed.deviceNotFoundMessage",
                defaultValue: "This computer was not found on this account. Make sure it is online and signed in to the same account. If it was wiped or set up again, it cannot be restored; you can remove this entry from the list below."
            )
        case .noIrohRoute:
            return L10n.string(
                "mobile.computers.unhideFailed.noIrohRouteMessage",
                defaultValue: "This Mac needs to finish updating its connection before it can be restored. Open cmux on it while it is online, then try again."
            )
        case .irohUnavailable:
            return L10n.string(
                "mobile.computers.unhideFailed.irohUnavailableMessage",
                defaultValue: "This iPhone hasn't finished setting up its connection service, so it can't search for the computer. Make sure you are signed in and online, then try again."
            )
        case .connectFailed:
            return L10n.string(
                "mobile.computers.unhideFailed.connectFailedMessage",
                defaultValue: "Found the computer, but couldn't connect to it. Check that both devices are online, then try again."
            )
        case nil:
            return genericRecoveryFailureMessage
        }
    }

    private var genericRecoveryFailureMessage: String {
        L10n.string(
            "mobile.computers.unhideFailedMessage",
            defaultValue: "This computer was removed with an older version of cmux. Open cmux on the Mac, make sure it is online and signed in to this account, then try again."
        )
    }

    private func recoveryAppDisplayName(for buildLabel: String) -> String? {
        switch buildLabel {
        case "Stable":
            return L10n.string("mobile.hostPicker.app.stable", defaultValue: "cmux")
        case "Nightly":
            return L10n.string(
                "mobile.computers.recovery.app.nightly",
                defaultValue: "cmux NIGHTLY"
            )
        case "RC":
            return L10n.string("mobile.hostPicker.app.rc", defaultValue: "cmux RC")
        case "Staging":
            return L10n.string(
                "mobile.hostPicker.app.staging",
                defaultValue: "cmux Staging"
            )
        case "DEV":
            return L10n.string("mobile.hostPicker.app.dev", defaultValue: "cmux DEV")
        default:
            let prefix = "DEV · "
            guard buildLabel.hasPrefix(prefix) else { return nil }
            return String(
                format: L10n.string(
                    "mobile.hostPicker.app.devTaggedFormat",
                    defaultValue: "cmux DEV %@"
                ),
                String(buildLabel.dropFirst(prefix.count))
            )
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
    let discardLegacyComputer: @MainActor (MobileHiddenComputer) async -> Void

    var body: some View {
        ForEach(computers) { computer in
            HiddenComputerRow(
                computer: computer,
                isRecoveringLegacyComputer: isRecoveringLegacyComputer,
                unhide: { await unhide(computer) },
                recoverLegacyComputer: { await recoverLegacyComputer(computer) },
                discardLegacyComputer: { await discardLegacyComputer(computer) }
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
    let discardLegacyComputer: @MainActor (MobileHiddenComputer) async -> Void

    var body: some View {
        Section {
            HiddenComputersRows(
                computers: computers,
                isRecoveringLegacyComputer: isRecoveringLegacyComputer,
                unhide: unhide,
                recoverLegacyComputer: recoverLegacyComputer,
                discardLegacyComputer: discardLegacyComputer
            )
        } header: {
            Text(HiddenComputersCopy.title)
        } footer: {
            Text(HiddenComputersCopy.footer)
        }
    }
}
#endif

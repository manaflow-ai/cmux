#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// Immutable hidden-computer row with an offline unhide action and a destructive
/// "Forget" action.
///
/// Unhide is the primary, reversible action (it only clears this iPhone's local
/// hide marker), so it stays as the inline trailing button. Forget is the
/// destructive one: it revokes the Mac's iroh binding for the whole account, so
/// it lives behind a swipe/context-menu plus a confirmation dialog, mirroring the
/// swipe+menu pattern `MacComputerRow` uses for Hide. No first tap commits the
/// revoke; the dialog's `.destructive` button does.
struct HiddenComputerRow: View {
    let computer: MobileHiddenComputer
    let unhide: @MainActor () async -> Void
    /// Revokes this Mac's binding for the account (via the store, which resolves
    /// the binding id from a fresh discovery). Presenting any failure feedback is
    /// the caller's job so the row stays a pure snapshot.
    let forget: @MainActor () async -> Void

    @State private var actionTask: Task<Void, Never>?
    @State private var forgetTask: Task<Void, Never>?
    @State private var showForgetConfirm = false

    private var isBusy: Bool { actionTask != nil || forgetTask != nil }

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
                if forgetTask != nil {
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
        .contextMenu { forgetMenuButton }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            forgetSwipeButton
        }
        .confirmationDialog(
            L10n.string(
                "mobile.computers.forget.confirmTitle",
                defaultValue: "Forget this computer?"
            ),
            isPresented: $showForgetConfirm,
            titleVisibility: .visible
        ) {
            Button(
                L10n.string("mobile.computers.forget", defaultValue: "Forget"),
                role: .destructive,
                action: performForget
            )
            .accessibilityIdentifier("MobileComputerForgetConfirmButton-\(computer.id)")
            Button(
                L10n.string("mobile.common.cancel", defaultValue: "Cancel"),
                role: .cancel
            ) {}
        } message: {
            Text(L10n.string(
                "mobile.computers.forget.confirmMessage",
                defaultValue: "It's removed from all your devices. If it's still online, it reappears the next time it connects."
            ))
        }
        .onDisappear {
            actionTask?.cancel()
            actionTask = nil
            forgetTask?.cancel()
            forgetTask = nil
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

    private var forgetSwipeButton: some View {
        Button(role: .destructive) {
            showForgetConfirm = true
        } label: {
            Label(
                L10n.string("mobile.computers.forget", defaultValue: "Forget"),
                systemImage: "trash"
            )
        }
        .disabled(isBusy)
        .accessibilityIdentifier("MobileComputerForgetSwipeButton-\(computer.id)")
    }

    private var forgetMenuButton: some View {
        Button(role: .destructive) {
            showForgetConfirm = true
        } label: {
            Label(
                L10n.string("mobile.computers.forget", defaultValue: "Forget"),
                systemImage: "trash"
            )
        }
        .disabled(isBusy)
        .accessibilityIdentifier("MobileComputerForgetMenuButton-\(computer.id)")
    }

    private func performUnhide() {
        guard !isBusy else { return }
        actionTask = Task { @MainActor in
            defer { actionTask = nil }
            await unhide()
        }
    }

    private func performForget() {
        guard !isBusy else { return }
        forgetTask = Task { @MainActor in
            defer { forgetTask = nil }
            await forget()
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
    let forget: @MainActor (MobileHiddenComputer) async -> Void

    var body: some View {
        ForEach(computers) { computer in
            HiddenComputerRow(
                computer: computer,
                unhide: { await unhide(computer) },
                forget: { await forget(computer) }
            )
        }
    }
}

/// The list-style Hidden Computers section shared by the Computers screen and
/// the disconnected shell.
struct HiddenComputersSection: View {
    let computers: [MobileHiddenComputer]
    let unhide: @MainActor (MobileHiddenComputer) async -> Void
    let forget: @MainActor (MobileHiddenComputer) async -> Void

    var body: some View {
        Section {
            HiddenComputersRows(
                computers: computers,
                unhide: unhide,
                forget: forget
            )
        } header: {
            Text(HiddenComputersCopy.title)
        } footer: {
            Text(HiddenComputersCopy.footer)
        }
    }
}
#endif

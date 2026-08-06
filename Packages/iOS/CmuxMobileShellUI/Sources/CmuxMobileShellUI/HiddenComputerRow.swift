#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// Immutable hidden-computer row with an offline visibility switch and a
/// destructive "Forget" action.
///
/// Showing the Mac is the primary, reversible action (it only clears this
/// iPhone's local hide marker), so it stays as the inline trailing switch.
/// Forget is destructive: it revokes the Mac's iroh binding for the whole
/// account, so it lives behind a swipe/context-menu plus a confirmation dialog.
/// No first tap commits the revoke; the dialog's `.destructive` button does.
struct HiddenComputerRow: View {
    let computer: MobileHiddenComputer
    let setVisible: (Bool) -> Void
    /// Revokes this Mac's binding for the account (via the store, which resolves
    /// the binding id from a fresh discovery). Presenting any failure feedback is
    /// the caller's job so the row stays a pure snapshot.
    let forget: (@MainActor () async -> Void)?

    @State private var forgetTask: Task<Void, Never>?
    @State private var showForgetConfirm = false

    private var isBusy: Bool { forgetTask != nil }

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
            ComputerVisibilityToggle(
                computerID: computer.id,
                computerName: computer.displayName,
                isVisible: false,
                setVisible: setVisible
            )
            .disabled(isBusy)
        }
        .padding(.vertical, 4)
        .contextMenu {
            if forget != nil {
                forgetMenuButton
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if forget != nil {
                forgetSwipeButton
            }
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

    /// Red like a destructive swipe action, but deliberately WITHOUT
    /// `role: .destructive`: a destructive-role swipe button makes SwiftUI
    /// batch-delete the row on tap, and this tap only presents the
    /// confirmation dialog, so the unchanged model count aborted in
    /// UIKit's item-count assertion (TestFlight crash, build
    /// 20260731052644). Same pattern as `WorkspaceNavigationRow`'s
    /// confirm-first Delete.
    private var forgetSwipeButton: some View {
        Button {
            showForgetConfirm = true
        } label: {
            Label(
                L10n.string("mobile.computers.forget", defaultValue: "Forget"),
                systemImage: "trash"
            )
        }
        .tint(.red)
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

    private func performForget() {
        guard !isBusy, let forget else { return }
        forgetTask = Task { @MainActor in
            defer { forgetTask = nil }
            await forget()
        }
    }
}

/// Shared row wiring for the visible and hidden computers in one section.
/// Takes immutable snapshots plus closures only; the store stays at the
/// caller's list boundary.
struct ComputerVisibilityRows: View {
    let visibleComputers: [MacComputerSnapshot]
    let hiddenComputers: [MobileHiddenComputer]
    var style: MacComputerRow.Style = .computers
    var connect: @MainActor (MacComputerSnapshot) -> Void = { _ in }
    var connectingComputerID: String?
    let hide: @MainActor (MacComputerSnapshot) async -> Void
    let unhide: @MainActor (MobileHiddenComputer) async -> Void
    var forget: (@MainActor (MobileHiddenComputer) async -> Void)? = nil

    var body: some View {
        ForEach(visibleComputers) { computer in
            MacComputerRow(
                computer: computer,
                setVisible: { visible in
                    guard !visible else { return }
                    Task { await hide(computer) }
                },
                style: style,
                connect: { _ in connect(computer) },
                isConnecting: connectingComputerID == computer.id
            )
        }
        ForEach(hiddenComputers) { computer in
            HiddenComputerRow(
                computer: computer,
                setVisible: { visible in
                    guard visible else { return }
                    Task { await unhide(computer) }
                },
                forget: forgetAction(for: computer)
            )
        }
    }

    private func forgetAction(
        for computer: MobileHiddenComputer
    ) -> (@MainActor () async -> Void)? {
        guard let forget else { return nil }
        return { await forget(computer) }
    }
}
#endif

#if os(iOS)
import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The Computers screen: the Macs signed in to the user's account, each shown
/// with its name, live/last-seen status, and workspace count. The main workspace
/// list owns the Mac picker; this screen manages the saved computer set and lets
/// users inspect or remove one. The data is the durable-object–backed device
/// registry (with a paired-Mac fallback) plus live presence.
///
/// Snapshot boundary (see AGENTS.md): every row below the `List` takes an
/// immutable ``MacComputerSnapshot`` value only — no `@Observable`/`store`
/// reference crosses into a row. The single `@Bindable store` lives here at the
/// boundary; actions are plain closures.
struct DeviceTreeView: View {
    @Bindable var store: CMUXMobileShellStore
    /// Open a workspace (forwarded from the shell). Unused by the management list
    /// today; kept so a future "show this computer's workspaces" tap can use it.
    let selectWorkspace: (MobileWorkspacePreview.ID) -> Void
    /// Present the add-device (pairing) flow. `nil` hides the add affordance.
    var showAddDevice: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    /// The computer whose destructive remove action is awaiting confirmation.
    /// Stored at list scope so reusable rows do not own transient presentation
    /// state while `List` is recycling swipe-action rows.
    @State private var computerPendingRemovalID: String?
    @State private var isRecoveringDeletedComputer = false
    @State private var recoveryAlertMessage: String?

    /// The user's computers as immutable snapshots, sourced from the paired-Mac
    /// backup (`pairedMacs`) — this feature's source of truth, the same set that
    /// feeds the workspace aggregation, and the one ``CMUXMobileShellStore/forgetMac``
    /// actually removes. (Building from `deviceTreeDevices`, which prefers the team
    /// registry, would make Remove ineffective: a registry-backed row reappears on
    /// the next registry load.) Each is enriched with presence, live status, and how
    /// many aggregated workspaces it contributes. Built by the shared
    /// ``MacComputerSnapshot/snapshots(from:)`` so the disconnected reconnect
    /// list shows exactly the same computer set.
    private var computers: [MacComputerSnapshot] {
        MacComputerSnapshot.snapshots(from: store)
    }

    var body: some View {
        NavigationStack {
            List {
                if computers.isEmpty {
                    emptySection
                } else {
                    Section {
                        ForEach(computers) { computer in
                            MacComputerRow(
                                computer: computer,
                                requestRemove: requestComputerRemoval,
                                isConfirmingRemove: removalConfirmationBinding(for: computer.id),
                                confirmRemove: { _ in confirmComputerRemoval() }
                            )
                        }
                        if showAddDevice != nil {
                            addComputerRow
                        }
                    } footer: {
                        Text(L10n.string(
                            "mobile.computers.footer",
                            defaultValue: "The computers signed in to your account. Use the workspace title picker to focus one computer or show All Computers."
                        ))
                    }
                }
                if store.hasRecoverableDeletedComputers {
                    deletedComputerRecoverySection
                }
            }
            .listStyle(.insetGrouped)
            .navigationDestination(for: String.self) { pairingID in
                if let computer = computers.first(where: { $0.id == pairingID }) {
                    MacComputerDetailView(
                        store: store,
                        macDeviceID: computer.deviceId,
                        instanceTag: computer.instanceTag
                    )
                }
            }
            .navigationTitle(L10n.string("mobile.computers.title", defaultValue: "Computers"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showAddDevice != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: addComputer) {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(L10n.string("mobile.computers.add", defaultValue: "Add Computer"))
                        .accessibilityIdentifier("MobileComputersAddButton")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.done", defaultValue: "Done")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("MobileDeviceTreeDone")
                }
            }
            .refreshable { await reload() }
            .alert(
                L10n.string(
                    "mobile.computers.recoverFailedTitle",
                    defaultValue: "Couldn't recover computer"
                ),
                isPresented: recoveryAlertPresented
            ) {
                Button(L10n.string("mobile.common.ok", defaultValue: "OK"), role: .cancel) {
                    recoveryAlertMessage = nil
                }
            } message: {
                Text(recoveryAlertMessage ?? "")
            }
            .task {
                // This screen is the user's connection-debug view. The online dots
                // (presence) and secondary workspace counts already update live via
                // push subscriptions, so keeping it "live" just needs a gentle,
                // timer-driven refresh of the local rows + connected foreground state.
                // `refreshComputersScreen()` deliberately does NOT dial offline Macs
                // on the timer (that would fan out a reconnect storm to every saved
                // Mac); presence-push recovery and the explicit pull-to-refresh /
                // per-Mac Reconnect button handle reconnects. The timer sequence is
                // cancelled on dismiss by the surrounding SwiftUI `.task`.
                await reload()
                for await _ in Timer.publish(every: 10, on: .main, in: .common).autoconnect().values {
                    await store.refreshComputersScreen()
                }
            }
        }
        .accessibilityIdentifier("MobileDeviceTree")
    }

    /// End-of-list affordance mirroring the top-left toolbar button, so users who
    /// scroll past their Macs can add another without scrolling back up. Same
    /// action path (`addComputer`) as the toolbar button.
    private var addComputerRow: some View {
        Button(action: addComputer) {
            Label(
                L10n.string("mobile.computers.add", defaultValue: "Add Computer"),
                systemImage: "plus"
            )
        }
        .accessibilityIdentifier("MobileComputersAddRow")
    }

    /// Present the add-device (pairing) flow, then dismiss this screen. Shared by
    /// the top-left toolbar button and the end-of-list row.
    private func addComputer() {
        showAddDevice?()
        dismiss()
    }

    @ViewBuilder
    private var deletedComputerRecoverySection: some View {
        Section {
            Button(action: recoverDeletedComputer) {
                Label {
                    Text(isRecoveringDeletedComputer
                        ? L10n.string(
                            "mobile.computers.recoveringDeleted",
                            defaultValue: "Recovering Deleted Computer…"
                        )
                        : L10n.string(
                            "mobile.computers.recoverDeleted",
                            defaultValue: "Recover Deleted Computer"
                        ))
                } icon: {
                    if isRecoveringDeletedComputer {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.uturn.backward")
                    }
                }
            }
            .disabled(isRecoveringDeletedComputer)
            .accessibilityIdentifier("MobileRecoverDeletedComputerButton")
        } footer: {
            Text(L10n.string(
                "mobile.computers.recoverDeletedFooter",
                defaultValue: "Deleted computers stay hidden on this phone. To recover one, open cmux on that Mac, sign in to this same account, then tap Recover Deleted Computer."
            ))
        }
    }

    @ViewBuilder
    private var emptySection: some View {
        Section {
            Text(L10n.string(
                "mobile.computers.empty",
                defaultValue: "No computers yet. Add one to see its workspaces here."
            ))
            .foregroundStyle(.secondary)
        }
    }

    private func requestComputerRemoval(_ pairingID: String) {
        computerPendingRemovalID = pairingID
    }

    private func removalConfirmationBinding(for deviceID: String) -> Binding<Bool> {
        Binding(
            get: { computerPendingRemovalID == deviceID },
            set: { isPresented in
                if isPresented {
                    computerPendingRemovalID = deviceID
                } else if computerPendingRemovalID == deviceID {
                    computerPendingRemovalID = nil
                }
            }
        )
    }

    private func confirmComputerRemoval() {
        guard let pairingID = computerPendingRemovalID,
              let computer = computers.first(where: { $0.id == pairingID }) else {
            return
        }
        computerPendingRemovalID = nil
        Task {
            await store.forgetMac(
                macDeviceID: computer.deviceId,
                instanceTag: computer.instanceTag
            )
            await reload()
        }
    }

    private var recoveryAlertPresented: Binding<Bool> {
        Binding(
            get: { recoveryAlertMessage != nil },
            set: { isPresented in
                if !isPresented { recoveryAlertMessage = nil }
            }
        )
    }

    private func recoverDeletedComputer() {
        guard !isRecoveringDeletedComputer else { return }
        isRecoveringDeletedComputer = true
        recoveryAlertMessage = nil
        Task {
            let recovered = await store.recoverForgottenIrohMacFromAccount()
            await reload()
            isRecoveringDeletedComputer = false
            if !recovered {
                recoveryAlertMessage = L10n.string(
                    "mobile.computers.recoverFailedMessage",
                    defaultValue: "No deleted computer was recovered. Open cmux on the Mac, sign in to this same account, and try again."
                )
            }
        }
    }

    private func reload() async {
        // Load the local paired Macs first so the list has a fallback source the
        // instant it appears, then refresh from the registry.
        await store.loadPairedMacs()
        await store.loadRegistryDevices()
    }
}
#endif

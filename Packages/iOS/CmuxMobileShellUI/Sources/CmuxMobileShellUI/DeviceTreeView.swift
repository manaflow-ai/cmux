#if os(iOS)
import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The Computers screen: the Macs signed in to the user's account, each shown
/// with its name, live/last-seen status, and workspace count. There is no longer
/// a "connect to a device" step — workspaces from every computer already appear
/// together in the main list — so this screen is now for *managing* computers:
/// see their details (online state, when last seen, how many workspaces) and add
/// or remove one. The data is the durable-object–backed device registry (with a
/// paired-Mac fallback) plus live presence.
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

    private var computers: [MacComputerSnapshot] {
        store.stableComputerSnapshots
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
                                isConfirmingRemove: removalConfirmationBinding(for: computer.deviceId),
                                confirmRemove: { _ in confirmComputerRemoval() }
                            )
                        }
                    } footer: {
                        Text(L10n.string(
                            "mobile.computers.footer",
                            defaultValue: "The Macs signed in to your account. Workspaces from every computer appear together in the main list."
                        ))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationDestination(for: String.self) { deviceId in
                MacComputerDetailView(store: store, macDeviceID: deviceId)
            }
            .navigationTitle(L10n.string("mobile.computers.title", defaultValue: "Computers"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showAddDevice != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showAddDevice?()
                            dismiss()
                        } label: {
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

    private func requestComputerRemoval(_ deviceID: String) {
        computerPendingRemovalID = deviceID
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
        guard let deviceID = computerPendingRemovalID else {
            return
        }
        computerPendingRemovalID = nil
        Task {
            await store.forgetMac(macDeviceID: deviceID)
            await reload()
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

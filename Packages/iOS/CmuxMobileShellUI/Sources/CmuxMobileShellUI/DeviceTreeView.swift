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

    /// The user's computers as immutable snapshots, sourced from the paired-Mac
    /// backup (`pairedMacs`) — this feature's source of truth, the same set that
    /// feeds the workspace aggregation, and the one ``CMUXMobileShellStore/forgetMac``
    /// actually removes. (Building from `deviceTreeDevices`, which prefers the team
    /// registry, would make Remove ineffective: a registry-backed row reappears on
    /// the next registry load.) Each is enriched with presence, live status, and how
    /// many aggregated workspaces it contributes.
    private var computers: [MacComputerSnapshot] {
        let colorIndex = store.machineColorIndex
        // The PHONE's own per-Mac connection (foreground or live secondary) — the
        // source of truth for the dot, distinct from presence.
        let connectionStatuses = store.macConnectionStatuses
        return store.displayPairedMacs.map { mac in
            let aliases = store.pairedMacAliasIDs(for: mac.macDeviceID)
            let summary = store.presenceSummary(for: mac.macDeviceID)
            let presence: DeviceTreePresence? = summary
                .map { $0.online ? .online : .offline(lastSeenAt: $0.lastSeenAt) }
            return MacComputerSnapshot(
                deviceId: mac.macDeviceID,
                title: mac.resolvedName,
                platform: "mac",
                colorIndex: aliases.compactMap { colorIndex[$0] }.first,
                customColor: mac.customColor,
                customIcon: mac.customIcon,
                connectionStatus: connectionStatuses[mac.macDeviceID],
                presence: presence,
                buildLabel: summary?.buildLabel,
                routeDescription: CmxAttachRoute.deviceTreeRouteDescription(for: mac.routes),
                lastSeenAt: mac.lastSeenAt,
                workspaceCount: store.workspaceCount(for: mac.macDeviceID),
                aliasIDs: aliases
            )
        }
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
                            defaultValue: "The Macs signed in to your account. Use the workspace title picker to focus one Mac or show All Macs."
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

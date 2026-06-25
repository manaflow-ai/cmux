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

    /// The computer pending a remove confirmation.
    @State private var pendingRemoval: MacComputerSnapshot?

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
                            NavigationLink(value: computer.deviceId) {
                                MacComputerRow(computer: computer)
                            }
                            .swipeActions(edge: .trailing) {
                                removeButton(for: computer)
                            }
                            .contextMenu {
                                removeButton(for: computer)
                            }
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
            .confirmationDialog(
                removeTitle(pendingRemoval),
                isPresented: removalDialogBinding,
                titleVisibility: .visible
            ) {
                if let pending = pendingRemoval {
                    Button(
                        L10n.string("mobile.computers.remove", defaultValue: "Remove"),
                        role: .destructive
                    ) {
                        let deviceId = pending.deviceId
                        pendingRemoval = nil
                        Task {
                            await store.forgetMac(macDeviceID: deviceId)
                            await reload()
                        }
                    }
                }
                Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel"), role: .cancel) {
                    pendingRemoval = nil
                }
            } message: {
                Text(removeMessage(pendingRemoval))
            }
        }
        .accessibilityIdentifier("MobileDeviceTree")
    }

    @ViewBuilder
    private func removeButton(for computer: MacComputerSnapshot) -> some View {
        Button(role: .destructive) {
            pendingRemoval = computer
        } label: {
            Label(
                L10n.string("mobile.computers.remove", defaultValue: "Remove"),
                systemImage: "trash"
            )
        }
        .accessibilityIdentifier("MobileComputerRemove-\(computer.deviceId)")
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

    private var removalDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { presented in if !presented { pendingRemoval = nil } }
        )
    }

    private func removeTitle(_ computer: MacComputerSnapshot?) -> String {
        String(
            format: L10n.string("mobile.computers.removeTitleFormat", defaultValue: "Remove %@?"),
            computer?.title ?? ""
        )
    }

    private func removeMessage(_: MacComputerSnapshot?) -> String {
        L10n.string(
            "mobile.computers.removeMessage",
            defaultValue: "This computer and its workspaces stop appearing here. Pair it again to add it back."
        )
    }

    private func reload() async {
        // Load the local paired Macs first so the list has a fallback source the
        // instant it appears, then refresh from the registry.
        await store.loadPairedMacs()
        await store.loadRegistryDevices()
    }
}
#endif

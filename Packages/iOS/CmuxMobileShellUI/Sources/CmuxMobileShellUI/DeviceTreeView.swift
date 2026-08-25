#if os(iOS)
import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The Computers screen: the user's Computers — paired Mac app instances
/// (device + build) — each shown once, grouped under the connection method
/// that Computer is configured to use (Iroh or Tailscale, set per Computer in
/// its configuration). The main workspace list owns the Mac picker; this
/// screen manages the saved set and lets users inspect one or choose whether
/// it appears on this iPhone. The data is the durable-object–backed device
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
    /// Live app routes dismiss through the root modal owner. Standalone hosts
    /// leave this nil and retain the environment dismissal fallback.
    var dismissAction: (() -> Void)? = nil
    @Environment(MobileConnectionMethodStore.self) private var connectionMethodStore:
        MobileConnectionMethodStore?

    /// The user's computers as immutable snapshots, sourced from the paired-Mac
    /// backup (`pairedMacs`) — this feature's source of truth, the same set that
    /// feeds the workspace aggregation, and the one ``CMUXMobileShellStore/hideMac``
    /// filters locally. Each is enriched with presence, live status, and how
    /// many aggregated workspaces it contributes. Hidden Macs remain in the
    /// same section with their switches off. Built by the shared
    /// ``MacComputerSnapshot/snapshots(from:)`` so the disconnected reconnect
    /// list shows exactly the same computer set.
    private var computers: [MacComputerSnapshot] {
        MacComputerSnapshot.snapshots(from: store)
    }

    var body: some View {
        NavigationStack {
            List {
                if computers.isEmpty && store.hiddenComputers.isEmpty {
                    emptySection
                } else {
                    // One row per Computer, grouped under the connection
                    // method that Computer is configured to use. The method
                    // itself is changed in the Computer's own configuration.
                    ForEach(MacComputerListSection.sections(from: computers)) { section in
                        Section {
                            ComputerVisibilityRows(
                                visibleComputers: section.computers,
                                hiddenComputers: [],
                                mutatingComputerIDs: store.computerVisibilityMutationIDs,
                                hide: hideComputer,
                                unhide: unhideComputer,
                            )
                        } header: {
                            Text(section.title)
                        }
                    }
                    if !store.hiddenComputers.isEmpty {
                        Section {
                            ComputerVisibilityRows(
                                visibleComputers: [],
                                hiddenComputers: store.hiddenComputers,
                                mutatingComputerIDs: store.computerVisibilityMutationIDs,
                                hide: hideComputer,
                                unhide: unhideComputer,
                            )
                        } header: {
                            Text(L10n.string(
                                "mobile.connections.hidden.title",
                                defaultValue: "Hidden Computers"
                            ))
                        }
                    }
                    Section {
                        if showAddDevice != nil {
                            addComputerRow
                        }
                    } footer: {
                        Text(L10n.string(
                            "mobile.connections.footer",
                            defaultValue: "Each computer connects using the method set in its own configuration. Turning a computer off hides its workspaces on this iPhone; it stays signed in to your account."
                        ))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationDestination(for: MacConnectionRef.self) { ref in
                if let computer = computers.first(where: { $0.id == ref.pairingID }) {
                    MacComputerDetailView(
                        store: store,
                        macDeviceID: computer.deviceId,
                        instanceTag: computer.instanceTag,
                        focusedRouteKind: ref.routeKind
                    )
                }
            }
            .navigationTitle(L10n.string("mobile.connections.title", defaultValue: "Computers"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showAddDevice != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: addComputer) {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(L10n.string("mobile.connections.add", defaultValue: "Add Computer"))
                        .accessibilityIdentifier("MobileComputersAddButton")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.done", defaultValue: "Done")) {
                        dismissScreen()
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

    /// End-of-list affordance mirroring the top-left toolbar button, so users who
    /// scroll past their Macs can add another without scrolling back up. Same
    /// action path (`addComputer`) as the toolbar button.
    private var addComputerRow: some View {
        Button(action: addComputer) {
            Label(
                L10n.string("mobile.connections.add", defaultValue: "Add Computer"),
                systemImage: "plus"
            )
        }
        .accessibilityIdentifier("MobileComputersAddRow")
    }

    /// Present the add-device (pairing) flow, then dismiss this screen. Shared by
    /// the top-left toolbar button and the end-of-list row.
    private func addComputer() {
        showAddDevice?()
        dismissScreen()
    }

    private func dismissScreen() {
        if let dismissAction {
            dismissAction()
        } else {
            dismiss()
        }
    }

    @ViewBuilder
    private var emptySection: some View {
        Section {
            Text(emptyDescription)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("MobileComputersEmptyDescription")
        }
    }

    private var emptyDescription: String {
        if connectionMethodStore?.method == .tailscale {
            return MobilePairingScannerSheet.emptyStateGuidanceText
        }
        return showAddDevice != nil
            ? L10n.string(
                "mobile.connections.empty",
                defaultValue: "No computers yet. Iroh finds Macs running cmux 0.64.20 or later. Both devices must be signed in to the same cmux account, and the Mac must keep cmux running while both devices are online. If any requirement is missing, the Mac will not appear automatically. To use Tailscale instead, open Settings, tap Connection Method, and choose Tailscale Only."
            )
            : L10n.string(
                "mobile.devices.emptyDescription",
                defaultValue: "For Iroh to find a Mac, run cmux 0.64.20 or later on the Mac, sign in to cmux on both devices with the same account, and keep cmux running on the Mac while both devices are online. If any requirement is missing, the Mac will not appear automatically. To use Tailscale instead, open Settings, tap Connection Method, and choose Tailscale Only."
            )
    }

    private func hideComputer(_ computer: MacComputerSnapshot) {
        store.requestHideStoredPairedMacEntries(
            representativeID: computer.id,
            aliasIDs: computer.aliasIDs
        )
    }

    private func unhideComputer(_ computer: MobileHiddenComputer) {
        store.requestUnhideMacDeviceID(
            computer.macDeviceID,
            instanceTag: computer.instanceTag
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

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
/// users inspect one or choose whether it appears on this iPhone. The data is
/// the durable-object–backed device
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
    /// Called after a successful Forget operation. The root host uses this to
    /// dismiss the Computers sheet when the final saved computer is gone.
    var didForgetComputer: (() -> Void)? = nil
    @Environment(MobileConnectionMethodStore.self) private var connectionMethodStore:
        MobileConnectionMethodStore?
    /// Message for the always-visible failure alert shown when a Forget cannot be
    /// completed. An alert, not a toast, so the error still surfaces while the
    /// toast presenter is disabled.
    @State private var forgetFailureMessage: String?

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
                    Section {
                        ComputerVisibilityRows(
                            visibleComputers: computers,
                            hiddenComputers: store.hiddenComputers,
                            mutatingComputerIDs: store.computerVisibilityMutationIDs,
                            hide: hideComputer,
                            unhide: unhideComputer,
                            forget: forgetComputer
                        )
                        if showAddDevice != nil {
                            addComputerRow
                        }
                    } footer: {
                        Text(L10n.string(
                            "mobile.computers.footer",
                            defaultValue: "Turn a computer off to hide its workspaces on this iPhone. It stays signed in to your account."
                        ))
                    }
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
        .alert(
            L10n.string(
                "mobile.computers.forget.failureTitle",
                defaultValue: "Couldn't forget computer"
            ),
            isPresented: Binding(
                get: { forgetFailureMessage != nil },
                set: { presented in if !presented { forgetFailureMessage = nil } }
            ),
            presenting: forgetFailureMessage
        ) { _ in
            Button(
                L10n.string("mobile.common.ok", defaultValue: "OK"),
                role: .cancel
            ) {
                forgetFailureMessage = nil
            }
        } message: { message in
            Text(message)
        }
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
                "mobile.computers.empty",
                defaultValue: "No computers yet. Auto-Connect finds Macs running cmux 0.64.20 or later. Both devices must be signed in to the same cmux account, and the Mac must keep cmux running while both devices are online. If any requirement is missing, the Mac will not appear automatically. To use Tailscale instead, open Settings, tap Connection Method, and choose Tailscale Only."
            )
            : L10n.string(
                "mobile.devices.emptyDescription",
                defaultValue: "For Auto-Connect to find a Mac, run cmux 0.64.20 or later on the Mac, sign in to cmux on both devices with the same account, and keep cmux running on the Mac while both devices are online. If any requirement is missing, the Mac will not appear automatically. To use Tailscale instead, open Settings, tap Connection Method, and choose Tailscale Only."
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

    private func forgetComputer(_ computer: MobileHiddenComputer) async {
        let forgot = await store.forgetHiddenComputer(computer)
        if !forgot {
            forgetFailureMessage = L10n.string(
                "mobile.computers.forget.failureMessage",
                defaultValue: "It's still signed in. Check your connection and try again."
            )
        } else {
            didForgetComputer?()
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

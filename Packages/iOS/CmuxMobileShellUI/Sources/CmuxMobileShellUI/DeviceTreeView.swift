#if os(iOS)
import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileSSH
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Live app routes dismiss through the root modal owner. Standalone hosts
    /// leave this nil and retain the environment dismissal fallback.
    var dismissAction: (() -> Void)? = nil
    /// Whether the Mac sections, pairing, and account-scoped reloads apply.
    /// `false` in the signed-out SSH-only shell (PRD D5), which lists only SSH
    /// computers.
    var macPairingAvailable = true
    /// The workspace list's computer filter; selecting an SSH computer here
    /// scopes the list to it (PRD D22).
    @AppStorage(WorkspaceMacSelection.storageKey) private var macSelection: WorkspaceMacSelection = .all
    @State private var path = NavigationPath()
    @State private var pendingSSHDeleteID: UUID?
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

    /// Which row lives in which section (method sections + Hidden Computers).
    /// The visibility switches mutate the store asynchronously, so the row's
    /// section move lands after the toggle's own transaction has ended;
    /// animating the list on this key keeps that move smooth. Keyed on
    /// membership only, so the 10s presence refresh (same rows, new status
    /// text) doesn't animate.
    private var rowMembership: [String] {
        MacComputerListSection.sections(from: computers).flatMap { section in
            [section.id] + section.computers.map(\.id)
        } + ["hidden"] + store.hiddenComputers.map(\.id)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !macPairingAvailable {
                    EmptyView()
                } else if computers.isEmpty && store.hiddenComputers.isEmpty {
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
                                setCaffeine: setCaffeine,
                                caffeineMutatingComputerIDs: store.caffeineMutatingPairingIDs,
                                gateWarningPairingIDs: store.macVersionUpdateRequiredPairingIDs,
                                hide: hideComputer,
                                unhide: unhideComputer
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
                                gateWarningPairingIDs: store.macVersionUpdateRequiredPairingIDs,
                                hide: hideComputer,
                                unhide: unhideComputer
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
                // SSH computers sit after the route-kind sections and show
                // even with no paired Macs (PRD D6).
                SSHComputersSection(
                    computers: SSHComputerRowSnapshot.snapshots(from: store.sshComputers),
                    actions: sshSectionActions
                )
            }
            .listStyle(.insetGrouped)
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: rowMembership)
            .navigationDestination(for: SSHComputerEditorTarget.self) { target in
                SSHComputerEditorView(
                    computers: store.sshComputers,
                    existing: target.hostID.flatMap { store.sshComputers.host(id: $0) },
                    showsCancel: false,
                    onFinish: { _ in
                        if !path.isEmpty { path.removeLast() }
                    }
                )
            }
            .alert(
                SSHCopy().deleteHostTitle,
                isPresented: Binding(
                    get: { pendingSSHDeleteID != nil },
                    set: { if !$0 { pendingSSHDeleteID = nil } }
                ),
                presenting: pendingSSHDeleteID
            ) { hostID in
                Button(SSHCopy().delete, role: .destructive) {
                    deleteSSHComputer(hostID)
                }
                .accessibilityIdentifier("ssh.delete.confirm")
                Button(SSHCopy().cancel, role: .cancel) {}
            } message: { _ in
                Text(SSHCopy().deleteHostMessage)
            }
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
                ToolbarItem(placement: .topBarLeading) {
                    if showAddDevice != nil, macPairingAvailable {
                        // Adding can mean pairing a Mac or saving an SSH
                        // computer, so the + offers both (HIG Menus).
                        Menu {
                            Button(action: addComputer) {
                                Label(SSHCopy().pairMacEllipsis, systemImage: "macbook.and.iphone")
                            }
                            .accessibilityIdentifier("ssh.addMenu.pairMac")
                            Button(action: addSSHComputer) {
                                Label(SSHCopy().addComputerEllipsis, systemImage: "terminal")
                            }
                            .accessibilityIdentifier("ssh.addMenu.ssh")
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(L10n.string("mobile.connections.add", defaultValue: "Add Computer"))
                        .accessibilityIdentifier("MobileComputersAddButton")
                    } else {
                        Button(action: addSSHComputer) {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(SSHCopy().addComputer)
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
                guard macPairingAvailable else { return }
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

    private var sshSectionActions: SSHComputersSectionActions {
        SSHComputersSectionActions(
            select: selectSSHComputer,
            edit: { path.append(SSHComputerEditorTarget.edit($0)) },
            disconnect: { hostID in
                let computers = store.sshComputers
                Task { await computers.disconnect(hostID: hostID) }
            },
            requestDelete: { pendingSSHDeleteID = $0 },
            add: addSSHComputer
        )
    }

    private func addSSHComputer() {
        path.append(SSHComputerEditorTarget.new)
    }

    /// PRD D22: an SSH computer opens its workspace list like a Mac. Scope the
    /// list to it, connect (which asks any first-connect questions above
    /// every screen), and return to the list.
    private func selectSSHComputer(_ hostID: UUID) {
        let deviceID = store.sshComputerDeviceID(hostID: hostID)
        macSelection = .machine(deviceID)
        let store = store
        Task { _ = await store.switchToMac(macDeviceID: deviceID) }
        dismissScreen()
    }

    private func deleteSSHComputer(_ hostID: UUID) {
        let computers = store.sshComputers
        if case .machine(let id) = macSelection, store.sshHostID(computerDeviceID: id) == hostID {
            macSelection = .all
        }
        Task { try? await computers.deleteHost(id: hostID) }
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
        let description = showAddDevice != nil
            ? L10n.string(
                "mobile.v2.connections.empty",
                defaultValue: "On your Mac, turn on Enable iOS pairing in cmux Settings. Select the same team on both devices and keep cmux running. Only Macs you own or have permission to connect to appear here."
            )
            : L10n.string(
                "mobile.v2.devices.emptyDescription",
                defaultValue: "On your Mac, turn on Enable iOS pairing in cmux Settings. Select the same team on both devices and keep cmux running. Only Macs you own or have permission to connect to appear here."
            )
        return "\(description) \(MobilePairingCopy().emptyWorkspaceMessage)"
    }

    private func hideComputer(_ computer: MacComputerSnapshot) {
        store.requestHideStoredPairedMacEntries(
            representativeID: computer.id,
            aliasIDs: computer.aliasIDs
        )
    }

    /// Leading-swipe keep-awake toggle: targets exactly the swiped Computer's
    /// own connection, never whichever Mac happens to be active.
    private func setCaffeine(_ computer: MacComputerSnapshot, _ enabled: Bool) {
        Task {
            await store.setCaffeineEnabled(
                enabled,
                macDeviceID: computer.deviceId,
                instanceTag: computer.instanceTag
            )
        }
    }

    private func unhideComputer(_ computer: MobileHiddenComputer) {
        store.requestUnhideMacDeviceID(
            computer.macDeviceID,
            instanceTag: computer.instanceTag
        )
    }

    private func reload() async {
        // These are independent account-scoped reads. Start them together so
        // the slower registry request cannot delay the paired-Mac list, while
        // each loader's generation gate keeps stale results from publishing.
        async let pairedMacs: Bool = store.loadPairedMacs()
        async let registryDevices: Void = store.loadRegistryDevices()
        _ = await pairedMacs
        await registryDevices
    }
}
#endif

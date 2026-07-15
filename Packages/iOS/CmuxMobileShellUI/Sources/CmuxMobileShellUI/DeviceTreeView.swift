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
    /// The registry session currently attaching; row identity keeps repeated
    /// taps from launching competing destructive Mac switches.
    @State private var pendingHandoffID: String?
    @State private var handoffTask: Task<Void, Never>?
    @State private var handoffGeneration: UInt64 = 0
    /// The advertised session that could not be resolved after attaching.
    @State private var failedHandoffSessionTitle: String?

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

    /// Account-private registry sessions are immutable row snapshots; the live
    /// RPC replaces them after a successful attach.
    private var handoffSessions: [RegistryLiveSessionSnapshot] {
        RegistryLiveSessionSnapshot.snapshots(from: store.registryDevices)
    }

    var body: some View {
        NavigationStack {
            List {
                if !handoffSessions.isEmpty {
                    handoffSection
                }
                if computers.isEmpty, handoffSessions.isEmpty {
                    emptySection
                } else if !computers.isEmpty {
                    Section {
                        ForEach(computers) { computer in
                            MacComputerRow(
                                computer: computer,
                                requestRemove: requestComputerRemoval,
                                isConfirmingRemove: removalConfirmationBinding(for: computer.deviceId),
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
                    .disabled(pendingHandoffID != nil)
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
        .alert(
            L10n.string("mobile.handoff.failure.title", defaultValue: "Couldn't Continue Session"),
            isPresented: Binding(
                get: { failedHandoffSessionTitle != nil },
                set: { if !$0 { failedHandoffSessionTitle = nil } }
            )
        ) {
            Button(L10n.string("mobile.common.ok", defaultValue: "OK"), role: .cancel) {}
        } message: {
            Text(L10n.string(
                "mobile.handoff.failure.message",
                defaultValue: "The session may have ended or its computer may be offline. Refresh and try again."
            ))
        }
        .interactiveDismissDisabled(pendingHandoffID != nil)
        .onDisappear(perform: cancelPendingHandoff)
        .accessibilityIdentifier("MobileDeviceTree")
    }

    private var handoffSection: some View {
        Section {
            ForEach(handoffSessions) { session in
                RegistryLiveSessionRow(
                    session: session,
                    isConnecting: pendingHandoffID == session.id,
                    continueSession: { continueSession(session) }
                )
                .disabled(pendingHandoffID != nil)
            }
        } header: {
            Text(L10n.string(
                "mobile.handoff.section.title",
                defaultValue: "Continue on This Device"
            ))
        } footer: {
            Text(L10n.string(
                "mobile.handoff.section.footer",
                defaultValue: "Choose a live session to connect to its computer and pick up where you left off."
            ))
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
        dismiss()
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

    private func continueSession(_ session: RegistryLiveSessionSnapshot) {
        guard pendingHandoffID == nil else { return }
        handoffGeneration &+= 1
        let generation = handoffGeneration
        pendingHandoffID = session.id
        let task = Task { @MainActor in
            defer {
                if handoffGeneration == generation {
                    pendingHandoffID = nil
                    handoffTask = nil
                }
            }
            guard !Task.isCancelled, handoffGeneration == generation else { return }
            guard let workspaceID = await store.prepareRegistrySessionHandoff(
                deviceID: session.deviceID,
                instanceTag: session.instanceTag,
                sessionID: session.sessionID,
                agentSessionID: session.agentSessionID,
                ifStillCurrent: { handoffGeneration == generation }
            ) else {
                guard !Task.isCancelled, handoffGeneration == generation else { return }
                await reload()
                guard !Task.isCancelled, handoffGeneration == generation else { return }
                failedHandoffSessionTitle = session.workspaceTitle
                return
            }
            guard !Task.isCancelled, handoffGeneration == generation else { return }
            selectWorkspace(workspaceID)
            dismiss()
        }
        handoffTask = task
    }

    private func cancelPendingHandoff() {
        handoffGeneration &+= 1
        handoffTask?.cancel()
        handoffTask = nil
        pendingHandoffID = nil
    }

    private func reload() async {
        // Load the local paired Macs first so the list has a fallback source the
        // instant it appears, then refresh from the registry.
        await store.loadPairedMacs()
        await store.loadRegistryDevices()
    }
}
#endif

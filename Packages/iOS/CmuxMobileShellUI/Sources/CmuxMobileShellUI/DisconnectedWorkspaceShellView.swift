import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileSupport
import CmuxMobileWorkspace
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

struct DisconnectedWorkspaceShellView: View {
    /// Whether this install has ever paired a Mac. Gates the
    /// Tailscale-inactive callout: its copy explains an unreachable Mac, which
    /// is misleading for a signed-in user who has not added a device yet (that
    /// user gets the pairing-flavored callout in the auto-presented sheet).
    let hasKnownPairedMac: Bool
    let showAddDevice: () -> Void
    let signOut: () -> Void
    /// The setup gate to highlight in the "Trouble connecting?" help (iOS only).
    /// The root passes `.macUnreachable` for a returning device whose stored Mac
    /// just failed to reconnect, and `.signedInNeverPaired` for a device that has
    /// never paired, so the help marks the user's real recovery step.
    var setupHelpHighlight: MobileSetupGuidanceState = .signedInNeverPaired
    /// The shell store, forwarded to the reused Settings sheet so the user can
    /// still switch to another paired Mac from the no-devices/offline state
    /// (this screen is the terminal not-connected state, reached after a stored
    /// Mac reconnect fails). `nil` in previews.
    var store: CMUXMobileShellStore?

    @Environment(\.tailscaleStatusMonitor) private var tailscaleStatusMonitor

    @State private var showingSettings = false

    #if os(iOS)
    @State private var isShowingSetupHelp = false
    /// The computer whose destructive remove action is awaiting confirmation.
    /// Stored at list scope so reusable rows do not own transient presentation
    /// state while `List` is recycling swipe-action rows.
    @State private var computerPendingRemovalID: String?
    /// The computer a reconnect attempt is in flight for. Also the re-entry
    /// guard: while non-nil, row taps are ignored.
    @State private var connectingMacID: String?
    /// The display name of the computer whose reconnect just failed, driving
    /// the failure alert. `nil` = no alert.
    @State private var connectFailedComputerName: String?
    #endif

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(L10n.string("mobile.workspaces.title", defaultValue: "Workspaces"))
                .mobileInlineNavigationTitle()
                .toolbar {
                    #if os(iOS)
                    ToolbarItem(placement: .topBarLeading) {
                        settingsMenu
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        addDeviceToolbarButton
                    }
                    #else
                    ToolbarItem {
                        settingsMenu
                    }
                    ToolbarItem {
                        addDeviceToolbarButton
                    }
                    #endif
                }
                .accessibilityIdentifier("MobileDisconnectedWorkspaceShell")
                .task {
                    // Load (and, via the backup decorator, restore) saved Macs so a
                    // known/restored Mac shows up here for one-tap reconnect. Only
                    // auto-present the pairing sheet when there is nothing to pick,
                    // so a returning user is not buried under the add-device flow.
                    await store?.loadPairedMacs()
                    if store?.pairedMacs.isEmpty ?? true {
                        showAddDevice()
                        return
                    }
                    #if os(iOS)
                    // Registry + presence enrich the rows (online dots, build
                    // labels). The timer then keeps presence and last-seen fresh
                    // while the app is parked on this screen; like the Computers
                    // screen it deliberately does NOT dial offline Macs (see
                    // `refreshComputersScreen()`), so no reconnect storm.
                    await store?.loadRegistryDevices()
                    for await _ in Timer.publish(every: 10, on: .main, in: .common).autoconnect().values {
                        await store?.refreshComputersScreen()
                    }
                    #endif
                }
        }
        #if os(iOS)
        .sheet(isPresented: $isShowingSetupHelp) {
            // A user on the never-paired/offline screen can reach the same
            // explicit setup-gate guidance shown in onboarding and Settings, so
            // the dead end is never silent. The highlighted gate reflects whether
            // this device has paired a Mac before (offline recovery) or not.
            SetupHelpView(highlight: setupHelpHighlight) { isShowingSetupHelp = false }
        }
        .sheet(isPresented: $showingSettings) {
            // Reuse the same Settings sheet the workspace list opens from its
            // 3-dots menu so the no-devices screen's chrome matches. There is no
            // connected host or QR to rescan here, but the store is forwarded so
            // a user whose active Mac went offline can still switch to another
            // paired Mac; the sheet also surfaces the account + Sign Out.
            MobileSettingsView(
                connectedHostName: "",
                rescanQR: nil,
                signOut: signOut,
                store: store
            )
        }
        .alert(
            connectFailedTitle,
            isPresented: Binding(
                get: { connectFailedComputerName != nil },
                set: { if !$0 { connectFailedComputerName = nil } }
            )
        ) {
            Button(L10n.string("mobile.common.ok", defaultValue: "OK"), role: .cancel) {}
        } message: {
            Text(L10n.string(
                "mobile.disconnected.connectFailedMessage",
                defaultValue: "Make sure the computer is awake and online, then try again."
            ))
        }
        #endif
    }

    #if os(iOS)
    /// Saved computers as the same coalesced snapshots the Computers screen
    /// shows, so a Mac paired under several stored ids is one row here too.
    private var savedComputers: [MacComputerSnapshot] {
        store.map { MacComputerSnapshot.snapshots(from: $0) } ?? []
    }

    @ViewBuilder
    private var content: some View {
        if !savedComputers.isEmpty {
            savedComputersList(savedComputers)
        } else {
            emptyState
        }
    }

    /// The returning-user state: a real list of the saved computers, one row per
    /// logical Mac, with presence, last-seen, tap-to-reconnect, and
    /// swipe-to-remove — the same row component as the Computers screen.
    /// Snapshot boundary (see AGENTS.md): rows receive immutable
    /// ``MacComputerSnapshot`` values and closures only, never the store.
    private func savedComputersList(_ computers: [MacComputerSnapshot]) -> some View {
        List {
            // When a paired Mac is unreachable and this device has no active
            // tailnet, lead with that explanation instead of leaving the user
            // to tap dead rows.
            if hasKnownPairedMac, tailscaleStatusMonitor?.status == .inactiveOrNotInstalled {
                Section {
                    TailscaleInactiveCallout(context: .disconnected)
                }
            }
            Section {
                ForEach(computers) { computer in
                    MacComputerRow(
                        computer: computer,
                        requestRemove: { computerPendingRemovalID = $0 },
                        isConfirmingRemove: removalConfirmationBinding(for: computer.deviceId),
                        confirmRemove: { _ in confirmComputerRemoval() },
                        style: .reconnect,
                        connect: { connect(to: $0, named: computer.title) },
                        isConnecting: connectingMacID == computer.deviceId
                    )
                }
            } header: {
                Text(L10n.string("mobile.devices.savedTitle", defaultValue: "Your Computers"))
            } footer: {
                Text(L10n.string(
                    "mobile.disconnected.listFooter",
                    defaultValue: "Tap a computer to reconnect. Swipe left to remove one."
                ))
            }
            Section {
                Button(action: showAddDevice) {
                    Label(
                        L10n.string("mobile.computers.add", defaultValue: "Add Computer"),
                        systemImage: "plus"
                    )
                }
                .accessibilityIdentifier("MobileShowAddDeviceButton")
                Button {
                    isShowingSetupHelp = true
                } label: {
                    Label(
                        L10n.string("mobile.devices.setupHelp", defaultValue: "Trouble connecting?"),
                        systemImage: "questionmark.circle"
                    )
                }
                .accessibilityIdentifier("MobileDisconnectedSetupHelpButton")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await store?.loadPairedMacs()
            await store?.loadRegistryDevices()
        }
        .accessibilityIdentifier("MobileDisconnectedSavedMacList")
    }

    /// The never-paired/empty state (also previews, where `store` is `nil`).
    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.devices.emptyTitle", defaultValue: "No devices"),
                systemImage: "desktopcomputer.and.iphone"
            )
        } description: {
            Text(L10n.string(
                "mobile.devices.emptyDescription",
                defaultValue: "Add a computer to start syncing terminal workspaces."
            ))
        } actions: {
            if hasKnownPairedMac, tailscaleStatusMonitor?.status == .inactiveOrNotInstalled {
                TailscaleInactiveCallout(context: .disconnected)
                    .frame(maxWidth: 320, alignment: .leading)
                    .padding(.bottom, 4)
            }
            Button(action: showAddDevice) {
                Text(L10n.string("mobile.addDevice.title", defaultValue: "Add Computer"))
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .accessibilityIdentifier("MobileShowAddDeviceButton")
            Button {
                isShowingSetupHelp = true
            } label: {
                Text(L10n.string("mobile.devices.setupHelp", defaultValue: "Trouble connecting?"))
            }
            .font(.callout)
            .accessibilityIdentifier("MobileDisconnectedSetupHelpButton")
        }
    }

    /// Reconnect this row's computer. `switchToMac` promotes a live secondary
    /// connection or re-dials the Mac after refreshing its routes from the
    /// per-user backup; on failure the user gets an explicit alert instead of a
    /// silently ignored tap.
    private func connect(to macDeviceID: String, named name: String) {
        guard connectingMacID == nil, let store else { return }
        connectingMacID = macDeviceID
        Task {
            let connected = await store.switchToMac(macDeviceID: macDeviceID)
            connectingMacID = nil
            if !connected {
                connectFailedComputerName = name
            }
        }
    }

    private var connectFailedTitle: String {
        String(
            format: L10n.string(
                "mobile.disconnected.connectFailedTitleFormat",
                defaultValue: "Couldn't connect to %@"
            ),
            connectFailedComputerName ?? ""
        )
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
            await store?.forgetMac(macDeviceID: deviceID)
            await store?.loadPairedMacs()
        }
    }
    #else
    /// Saved Macs restored/known on this device (macOS fallback shell).
    private var savedMacs: [MobilePairedMac] { store?.pairedMacs ?? [] }

    private var content: some View {
        ContentUnavailableView {
            Label(
                savedMacs.isEmpty
                    ? L10n.string("mobile.devices.emptyTitle", defaultValue: "No devices")
                    : L10n.string("mobile.devices.savedTitle", defaultValue: "Your Computers"),
                systemImage: "desktopcomputer.and.iphone"
            )
        } description: {
            Text(
                savedMacs.isEmpty
                    ? L10n.string("mobile.devices.emptyDescription", defaultValue: "Add a computer to start syncing terminal workspaces.")
                    : L10n.string("mobile.devices.savedDescription", defaultValue: "Tap a saved computer to reconnect, or add another.")
            )
        } actions: {
            if hasKnownPairedMac, tailscaleStatusMonitor?.status == .inactiveOrNotInstalled {
                TailscaleInactiveCallout(context: .disconnected)
                    .frame(maxWidth: 320, alignment: .leading)
                    .padding(.bottom, 4)
            }
            if let store, !savedMacs.isEmpty {
                VStack(spacing: 8) {
                    ForEach(savedMacs) { mac in
                        Button {
                            Task { await store.switchToMac(macDeviceID: mac.macDeviceID) }
                        } label: {
                            Label(mac.displayName ?? mac.macDeviceID, systemImage: "desktopcomputer")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("MobileDisconnectedSavedMac-\(mac.macDeviceID)")
                    }
                }
                .frame(maxWidth: 320)
                .padding(.bottom, 4)
            }
            Button(action: showAddDevice) {
                Text(
                    savedMacs.isEmpty
                        ? L10n.string("mobile.addDevice.title", defaultValue: "Add Computer")
                        : L10n.string("mobile.addDevice.another", defaultValue: "Add another Computer")
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .accessibilityIdentifier("MobileShowAddDeviceButton")
        }
    }
    #endif

    /// The top-left 3-dots overflow, matching ``WorkspaceListView``'s
    /// `settingsMenu` so switching between the connected and no-devices screens
    /// is not jarring. On iOS it opens the full Settings sheet (which holds Sign
    /// Out); on macOS it is an inline menu with Sign Out as an item.
    private var settingsMenu: some View {
        #if os(iOS)
        Button {
            showingSettings = true
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(L10n.string("mobile.workspaces.settings", defaultValue: "Settings"))
        .accessibilityIdentifier("MobileWorkspaceSettingsMenu")
        #else
        Menu {
            Button(role: .destructive) {
                signOut()
            } label: {
                Label(
                    L10n.string("mobile.signOut", defaultValue: "Sign Out"),
                    systemImage: "rectangle.portrait.and.arrow.right"
                )
            }
            .accessibilityIdentifier("MobileWorkspaceSignOutMenuItem")
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(L10n.string("mobile.workspaces.settings", defaultValue: "Settings"))
        .accessibilityIdentifier("MobileWorkspaceSettingsMenu")
        #endif
    }

    private var addDeviceToolbarButton: some View {
        Button(action: showAddDevice) {
            Image(systemName: "plus")
        }
        .accessibilityLabel(L10n.string("mobile.addDevice.title", defaultValue: "Add Computer"))
        .accessibilityIdentifier("MobileShowAddDeviceToolbarButton")
    }
}

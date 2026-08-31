import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileWorkspace
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

struct DisconnectedWorkspaceShellView: View {
    /// Whether this install has ever paired a Mac. Used to distinguish first
    /// setup from reconnect guidance.
    let hasKnownPairedMac: Bool
    /// Present manual pairing. `nil` when the selected connection method cannot
    /// use the Tailscale route that pairing authorizes.
    let showAddDevice: (() -> Void)?
    let showPairingScanner: (() -> Void)?
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
    /// Whether Tailscale still needs its one-time Mac authorization. The
    /// requirement is rendered in the empty state instead of a top banner.
    var tailscalePairingRequired = false
    var showSettings: () -> Void = {}
    /// Present the Computers management sheet. Essential while disconnected:
    /// the per-Computer connection method lives in the Computer detail, and a
    /// Computer stuck on an undialable method (Tailscale Only with no grant)
    /// can ONLY be fixed from there.
    var showComputers: (() -> Void)? = nil
    var setupHelpPresentation = MobileChildSheetPresentation()

    #if os(iOS)
    @Environment(MobileConnectionMethodStore.self) private var connectionMethodStore:
        MobileConnectionMethodStore?
    #endif

    /// The connection-method check is kept behind a platform-neutral property
    /// so the shared view body never reaches directly into the iOS environment.
    private var usesTailscaleConnectionMethod: Bool {
        #if os(iOS)
        return connectionMethodStore?.method == .tailscale
        #else
        return false
        #endif
    }

    #if os(iOS)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    if let showComputers {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(action: showComputers) {
                                Image(systemName: "desktopcomputer")
                            }
                            .accessibilityLabel(L10n.string(
                                "mobile.connections.title",
                                defaultValue: "Computers"
                            ))
                            .accessibilityIdentifier("MobileWorkspaceDevicesButton")
                        }
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
                    // known/restored Mac shows up here for one-tap reconnect.
                    // Same-account discovery is the primary path. Manual pairing
                    // is available only when the root supplies its Tailscale action.
                    await store?.loadPairedMacs()
                    #if os(iOS)
                    // Registry + presence enrich the rows (online dots, build
                    // labels). The loop then keeps presence and last-seen fresh
                    // while the app is parked on this screen; like the Computers
                    // screen it deliberately does NOT dial offline Macs (see
                    // `refreshComputersScreen()`), so no reconnect storm.
                    // Cancellation is wired to this `.task`'s lifecycle.
                    await store?.loadRegistryDevices()
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(10))
                        guard !Task.isCancelled else { break }
                        await store?.refreshComputersScreen()
                    }
                    #endif
                }
        }
        #if os(iOS)
        .sheet(
            isPresented: setupHelpPresentation.isPresented,
            onDismiss: setupHelpPresentation.didDismiss
        ) {
            // A user on the never-paired/offline screen can reach the same
            // explicit setup-gate guidance shown in onboarding and Settings, so
            // the dead end is never silent. The highlighted gate reflects whether
            // this device has paired a Mac before (offline recovery) or not.
            SetupHelpView(
                highlight: setupHelpHighlight,
                onDone: setupHelpPresentation.dismiss
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
            Text(connectFailedMessage)
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
        if !savedComputers.isEmpty || !(store?.hiddenComputers.isEmpty ?? true) {
            savedComputersList(savedComputers)
        } else {
            emptyState
        }
    }

    /// The returning-user state: a real list of the saved computers, one row per
    /// logical Mac, with presence, last-seen, tap-to-reconnect, and an inline
    /// visibility switch. Hidden Macs stay in the same section with switches off.
    /// Snapshot boundary (see AGENTS.md): rows receive immutable
    /// ``MacComputerSnapshot`` values and closures only, never the store.
    private func savedComputersList(_ computers: [MacComputerSnapshot]) -> some View {
        List {
            Section {
                ComputerVisibilityRows(
                    visibleComputers: computers,
                    hiddenComputers: store?.hiddenComputers ?? [],
                    style: .reconnect,
                    connect: connect,
                    connectingComputerID: connectingMacID,
                    mutatingComputerIDs: store?.computerVisibilityMutationIDs ?? [],
                    hide: hideComputer,
                    unhide: unhideComputer
                )
            } header: {
                Text(L10n.string("mobile.connections.savedTitle", defaultValue: "Your Computers"))
            } footer: {
                Text(L10n.string(
                    "mobile.connections.disconnected.listFooter",
                    defaultValue: "Tap a shown computer to reconnect. Use its switch to show or hide it on this iPhone."
                ))
            }
            Section {
                if let showAddDevice {
                    Button(action: showAddDevice) {
                        Label(
                            L10n.string("mobile.connections.add", defaultValue: "Add Computer"),
                            systemImage: "plus"
                        )
                    }
                    .accessibilityIdentifier("MobileShowAddDeviceButton")
                }
                Button {
                    setupHelpPresentation.present()
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
        // The visibility switches mutate the store asynchronously, so a row's
        // move between the shown and hidden runs of the section lands after
        // the toggle's own transaction has ended; animating on membership
        // keeps that reorder smooth. Keyed on ids only, so the 10s presence
        // refresh (same rows, new status text) doesn't animate.
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.3),
            value: computers.map(\.id) + ["hidden"] + (store?.hiddenComputers.map(\.id) ?? [])
        )
        .refreshable {
            // Same refresh the 10s loop performs (plus registry), so a pull
            // updates the presence/last-seen the rows lead with, not just the
            // stored Mac list.
            await store?.refreshComputersScreen()
            await store?.loadRegistryDevices()
        }
        .accessibilityIdentifier("MobileDisconnectedSavedMacList")
    }

    /// The never-paired/empty state (also previews, where `store` is `nil`).
    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.connections.emptyTitle", defaultValue: "No Computers"),
                systemImage: "desktopcomputer.and.iphone"
            )
        } description: {
            Text(emptyDescription)
                .accessibilityIdentifier("MobileDisconnectedEmptyDescription")
        } actions: {
            if usesTailscaleConnectionMethod, let showPairingScanner {
                Button(action: showPairingScanner) {
                    Text(L10n.string(
                        "mobile.tailscalePairingRequired.scan",
                        defaultValue: "Scan Pairing Code"
                    ))
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .accessibilityIdentifier("MobileDisconnectedScanPairingCode")
            } else if let showAddDevice {
                Button(action: showAddDevice) {
                    Text(L10n.string("mobile.connections.add", defaultValue: "Add Computer"))
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .accessibilityIdentifier("MobileShowAddDeviceButton")
            }
            Button {
                setupHelpPresentation.present()
            } label: {
                Text(L10n.string("mobile.devices.setupHelp", defaultValue: "Trouble connecting?"))
            }
            .font(.callout)
            .accessibilityIdentifier("MobileDisconnectedSetupHelpButton")
        }
    }

    private var emptyDescription: String {
        #if os(iOS)
        if usesTailscaleConnectionMethod {
            return MobilePairingScannerSheet.emptyStateGuidanceText
        }
        #endif
        return MobileConnectionGuidanceText.discoveryRequirementsGuidance
    }

    /// Reconnect this row's computer. `switchToMac` promotes a live secondary
    /// connection or re-dials the Mac after refreshing its routes from the
    /// per-user backup; on failure the user gets an explicit alert instead of a
    /// silently ignored tap. `switchToMac` also returns `false` when a newer
    /// switch (e.g. from the Settings sheet's host picker) supersedes this one;
    /// in that case the newer attempt is still in flight or has already
    /// connected, and alerting "couldn't connect" would be wrong — skip it.
    private func connect(to computer: MacComputerSnapshot) {
        if tailscalePairingRequired {
            showPairingScanner?()
            return
        }
        guard connectingMacID == nil, let store else { return }
        connectingMacID = computer.id
        Task {
            let connected = await store.switchToMac(
                macDeviceID: computer.deviceId,
                instanceTag: computer.instanceTag
            )
            connectingMacID = nil
            if !connected,
               store.connectionState != .connected,
               !store.isMacSwitchInFlight {
                connectFailedComputerName = computer.title
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

    /// The reconnect attempt owns the store's latest classified failure. Show
    /// it with its guidance, falling back only when no specific reason exists.
    private var connectFailedMessage: String {
        if let failure = MobileDisconnectedFailureCopy(
            error: store?.connectionError,
            guidance: store?.connectionErrorGuidance
        ).combined {
            return failure
        }
        return L10n.string(
            "mobile.disconnected.connectFailedMessage",
            defaultValue: "Make sure the computer is awake and online, then try again."
        )
    }

    private func hideComputer(_ computer: MacComputerSnapshot) {
        store?.requestHideStoredPairedMacEntries(
            representativeID: computer.id,
            aliasIDs: computer.aliasIDs
        )
    }

    private func unhideComputer(_ computer: MobileHiddenComputer) {
        store?.requestUnhideMacDeviceID(
            computer.macDeviceID,
            instanceTag: computer.instanceTag
        )
    }
    #else
    /// Saved Macs restored/known on this device (macOS fallback shell).
    private var savedMacs: [MobilePairedMac] { store?.pairedMacs ?? [] }

    private var savedMacDescription: String {
        guard showAddDevice != nil else {
            return L10n.string(
                "mobile.connections.savedDescription.reconnectOnly",
                defaultValue: "Tap a saved computer to reconnect."
            )
        }
        return L10n.string(
            "mobile.connections.savedDescription",
            defaultValue: "Tap a saved computer to reconnect, or add another."
        )
    }

    private var content: some View {
        ContentUnavailableView {
            Label(
                savedMacs.isEmpty
                    ? L10n.string("mobile.connections.emptyTitle", defaultValue: "No Computers")
                    : L10n.string("mobile.connections.savedTitle", defaultValue: "Your Computers"),
                systemImage: "desktopcomputer.and.iphone"
            )
        } description: {
            Text(
                savedMacs.isEmpty
                    ? MobileConnectionGuidanceText.discoveryRequirementsGuidance
                    : savedMacDescription
            )
        } actions: {
            if let store, !savedMacs.isEmpty {
                VStack(spacing: 8) {
                    ForEach(savedMacs) { mac in
                        Button {
                            Task {
                                await store.switchToMac(
                                    macDeviceID: mac.macDeviceID,
                                    instanceTag: mac.instanceTag
                                )
                            }
                        } label: {
                            Label(mac.displayName ?? mac.macDeviceID, systemImage: "desktopcomputer")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("MobileDisconnectedSavedMac-\(mac.id)")
                    }
                }
                .frame(maxWidth: 320)
                .padding(.bottom, 4)
            }
            if let showAddDevice {
                Button(action: showAddDevice) {
                    Text(
                        savedMacs.isEmpty
                            ? L10n.string("mobile.connections.add", defaultValue: "Add Computer")
                            : L10n.string("mobile.connections.addAnother", defaultValue: "Add another Computer")
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .accessibilityIdentifier("MobileShowAddDeviceButton")
            }
        }
    }
    #endif

    /// The top-left settings entrypoint, matching ``WorkspaceListView``'s
    /// `settingsMenu` so switching between the connected and no-devices screens
    /// is not jarring. On iOS it is a Settings button that opens the full sheet
    /// (which holds Sign Out); on macOS it is an inline overflow menu with Sign
    /// Out as an item.
    private var settingsMenu: some View {
        #if os(iOS)
        Button {
            showSettings()
        } label: {
            MobileWorkspaceSettingsIcon()
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

    @ViewBuilder
    private var addDeviceToolbarButton: some View {
        if let showAddDevice {
            Button(action: showAddDevice) {
                Image(systemName: "plus")
            }
            .accessibilityLabel(L10n.string("mobile.connections.add", defaultValue: "Add Computer"))
            .accessibilityIdentifier("MobileShowAddDeviceToolbarButton")
        }
    }
}

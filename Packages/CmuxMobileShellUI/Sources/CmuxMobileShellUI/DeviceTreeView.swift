#if os(iOS)
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The hierarchical device tree: the team's registered devices (Macs/hosts) →
/// their cmux app instances (tags) → that instance's workspaces → tap to open.
///
/// This is the new primary multi-device navigation, built on the merged device
/// registry (`GET /api/devices`, the `devices` + `device_app_instances` tables).
/// Each top-level row is a registered device with its live or last-seen state;
/// expanding a device reveals its tagged builds; expanding a tag reveals that
/// build's workspaces. Workspaces only populate for the *currently connected*
/// instance (the registry carries routes, not workspaces); tapping a tag that is
/// not connected connects to it first, after which its workspaces appear.
///
/// Snapshot boundary (see AGENTS.md): every row below the `List` boundary takes
/// immutable value snapshots plus a closure action bundle (``DeviceTreeActions``)
/// only — no `@Observable`/`store` reference crosses into a row, so an orthogonal
/// `@Published` change can't thrash the lazy list. The single `@Bindable store`
/// lives here at the boundary; below it everything is values.
struct DeviceTreeView: View {
    @Bindable var store: CMUXMobileShellStore
    /// Open a workspace (the existing tap-to-open path). Forwarded from the shell.
    let selectWorkspace: (MobileWorkspacePreview.ID) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Persisted expansion shape, encoded as a newline-separated id string.
    @AppStorage("cmux.mobile.deviceTree.expanded") private var expandedStorage = ""
    @State private var isRefreshing = false
    /// Presents the add-device pairing flow (the same ``PairingView`` the
    /// first-run path uses), so another device can be paired from here at any
    /// time — not only while disconnected.
    @State private var isShowingAddDevice = false

    private var expansion: DeviceTreeExpansionStore {
        DeviceTreeExpansionStore(storage: expandedStorage)
    }

    /// Devices the phone can attach to (mac/linux/windows hosts). The phone never
    /// controls itself, so an `ios` row is filtered out rather than shown as a
    /// tappable, dead host. Sourced from ``CMUXMobileShellStore/deviceTreeDevices``
    /// so it falls back to locally paired Macs when the registry is unavailable.
    private var controllableDevices: [RegistryDevice] {
        store.deviceTreeDevices.filter(\.isControllableHost)
    }

    var body: some View {
        NavigationStack {
            List {
                if controllableDevices.isEmpty {
                    emptySection
                } else {
                    ForEach(controllableDevices) { device in
                        deviceSection(device)
                    }
                }

                addDeviceSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.string("mobile.deviceTree.title", defaultValue: "Devices"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: beginAddDevice) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L10n.string("mobile.addDevice.title", defaultValue: "Add device"))
                    .accessibilityIdentifier("MobileDeviceTreeAddDeviceToolbar")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.done", defaultValue: "Done")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("MobileDeviceTreeDone")
                }
            }
            .refreshable {
                await store.loadPairedMacs()
                await store.loadRegistryDevices()
            }
            .task {
                // Load the local paired Macs first so the tree has a fallback
                // source the instant it appears, then refresh from the registry.
                await store.loadPairedMacs()
                await store.loadRegistryDevices()
            }
            .sheet(isPresented: $isShowingAddDevice) {
                addDeviceSheet
            }
        }
        .accessibilityIdentifier("MobileDeviceTree")
    }

    /// One always-available entry into the pairing flow (the list row); the
    /// toolbar `plus` invokes the same ``beginAddDevice()`` action, per the
    /// shared-behavior policy (one action path for every entrypoint).
    @ViewBuilder
    private var addDeviceSection: some View {
        Section {
            Button(action: beginAddDevice) {
                Label(
                    L10n.string("mobile.addDevice.title", defaultValue: "Add device"),
                    systemImage: "plus"
                )
            }
            .accessibilityIdentifier("MobileDeviceTreeAddDevice")
        }
    }

    /// The first-run pairing flow, re-entered in place: QR scan or manual
    /// host, driven by the same store mutations as the root pairing path. On
    /// success the attempt leaves the shell connected to the new device, so
    /// the sheet dismisses and the tree refreshes to show it. The underlying
    /// pairing path is destructive on failure, so each attempt captures the
    /// Mac that was live when it started and ``finishAddDevice(previousMacDeviceID:)``
    /// reconnects it when the attempt ends disconnected.
    private var addDeviceSheet: some View {
        PairingView(
            pairingCode: $store.pairingCode,
            connectionError: store.connectionError,
            connectionErrorGuidance: store.connectionErrorGuidance,
            connectPairingCode: {
                let previousMacDeviceID = liveMacDeviceID
                await store.connectPairingInput()
                finishAddDevice(previousMacDeviceID: previousMacDeviceID)
            },
            connectManualHost: { name, host, port in
                let previousMacDeviceID = liveMacDeviceID
                await store.connectManualHost(name: name, host: host, port: port)
                finishAddDevice(previousMacDeviceID: previousMacDeviceID)
            },
            cancelPairing: {
                // Cancelling a sheet opened over a live connection must not
                // tear that connection down; `cancelPairing()` flips the store
                // to `.disconnected`. Pure decision, unit tested. A cancel
                // mid-attempt is handled by the attempt's own continuation:
                // the store ends the cancelled attempt `.disconnected`, and
                // `finishAddDevice` restores the previous Mac.
                if addDevicePolicy.cancelResetsPairingState(connectionState: store.connectionState) {
                    store.cancelPairing()
                }
            },
            cancel: { isShowingAddDevice = false }
        )
        .presentationDragIndicator(.visible)
    }

    private var addDevicePolicy: DeviceTreeAddDevicePolicy { DeviceTreeAddDevicePolicy() }

    /// The device id of the currently live Mac, captured before a pairing
    /// attempt so a destructive failure can restore it. `nil` when not
    /// connected (nothing to restore).
    private var liveMacDeviceID: String? {
        store.connectionState == .connected ? store.connectedMacDeviceID : nil
    }

    private func beginAddDevice() {
        isShowingAddDevice = true
    }

    /// Called after a pairing attempt from the add-device sheet completes.
    ///
    /// Success (the shell is connected, to the added device): dismiss the
    /// sheet and refresh both device sources so the new device appears in the
    /// tree. Cancellation over what was a live connection (disconnected, no
    /// connection error): the pairing path has already torn that connection
    /// down, so reconnect the previous Mac via
    /// ``CMUXMobileShellStore/switchToMac(macDeviceID:)`` instead of
    /// stranding the user. The restore runs in a fresh unstructured `Task`
    /// because a cancelled attempt's continuation executes in an
    /// already-cancelled task. A real failure (connection error set) does not
    /// restore — the reconnect would clear the error the user needs to read;
    /// the disconnected shell auto-presents the pairing sheet with that error
    /// for an in-place retry (see the policy's rationale).
    private func finishAddDevice(previousMacDeviceID: String?) {
        let state = store.connectionState
        if addDevicePolicy.dismissesAfterPairingAttempt(connectionState: state) {
            isShowingAddDevice = false
            Task {
                await store.loadPairedMacs()
                await store.loadRegistryDevices()
            }
            return
        }
        if addDevicePolicy.restoresPreviousConnection(
            connectionState: state,
            previousMacDeviceID: previousMacDeviceID,
            hasConnectionError: store.connectionError != nil
        ), let previousMacDeviceID {
            let store = store
            Task {
                await store.switchToMac(macDeviceID: previousMacDeviceID)
            }
        }
    }

    @ViewBuilder
    private var emptySection: some View {
        Section {
            Text(L10n.string(
                "mobile.deviceTree.empty",
                defaultValue: "No registered devices yet. Pair a Mac to see it here."
            ))
            .foregroundStyle(.secondary)
        } footer: {
            Text(L10n.string(
                "mobile.deviceTree.footer",
                defaultValue: "Devices and their cmux builds come from your team's registry. Tap a build to connect, then a workspace to open it."
            ))
        }
    }

    @ViewBuilder
    private func deviceSection(_ device: RegistryDevice) -> some View {
        let connectedID = store.connectedMacDeviceID
        let isConnectedDevice = device.deviceId == connectedID
        // Live status only exists for the connected device; others are described
        // by their registry "last seen" (best-effort liveness, no active ping).
        // The live *tag* on a multi-tag device is identified by route match (see
        // instanceMatchesActiveRoute), so per-instance liveness is correct.
        // TODO(device-tree): there is still no active per-host reachability ping
        // for non-connected devices, so their dot is last-seen-only. Surface a
        // real ping once the host advertises one.
        let liveStatus: MobileMacConnectionStatus? = isConnectedDevice ? store.macConnectionStatus : nil

        Section {
            DeviceTreeDeviceRow(
                device: DeviceTreeDeviceSnapshot(
                    deviceId: device.deviceId,
                    title: device.title,
                    platform: device.platform,
                    lastSeenAt: device.lastSeenAt,
                    instanceCount: device.instances.count,
                    isConnected: isConnectedDevice,
                    liveStatus: liveStatus
                ),
                isExpanded: expansion.isExpanded(deviceExpansionID(device)),
                setExpanded: { expanded in setExpanded(deviceExpansionID(device), expanded) }
            )

            if expansion.isExpanded(deviceExpansionID(device)) {
                ForEach(device.instances) { instance in
                    instanceRows(device: device, instance: instance, isConnectedDevice: isConnectedDevice)
                }
            }
        }
    }

    @ViewBuilder
    private func instanceRows(
        device: RegistryDevice,
        instance: RegistryAppInstance,
        isConnectedDevice: Bool
    ) -> some View {
        let expansionID = instanceExpansionID(device: device, instance: instance)
        // Attribute the live workspace list to the ONE instance whose route
        // matches the live connection, not to every tag on the connected device.
        // The attach ticket carries no tag, so we identify the active build by
        // route identity (`activeRoute` endpoint ⊂ this instance's routes). A
        // multi-tag Mac therefore shows workspaces only under the build that is
        // actually connected; the other tags offer a Connect affordance instead
        // of (wrongly) mirroring another build's workspaces.
        let isActiveInstance = isConnectedDevice && instanceMatchesActiveRoute(instance)
        let workspaces = isActiveInstance ? store.workspaces : []
        let captured = DeviceTreeInstanceCapture(
            deviceId: device.deviceId,
            displayName: device.displayName,
            tag: instance.tag,
            routes: instance.routes
        )
        // No Connect affordance for the build that is already live; every other
        // route-bearing tag gets one.
        let connect = isActiveInstance ? nil : connectClosure(for: captured)

        DeviceTreeInstanceRow(
            instance: DeviceTreeInstanceSnapshot(
                tag: instance.tag,
                lastSeenAt: instance.lastSeenAt,
                hasRoutes: instance.hasRoutes,
                workspaceCount: workspaces.count,
                isActiveInstance: isActiveInstance
            ),
            isExpanded: expansion.isExpanded(expansionID),
            setExpanded: { expanded in setExpanded(expansionID, expanded) },
            connect: connect
        )

        if expansion.isExpanded(expansionID) {
            if workspaces.isEmpty {
                DeviceTreeWorkspacePlaceholderRow(
                    isActiveInstance: isActiveInstance,
                    hasRoutes: instance.hasRoutes,
                    connect: connect
                )
            } else {
                ForEach(workspaces) { workspace in
                    WorkspaceNavigationRow(
                        workspace: workspace,
                        connectionStatus: store.macConnectionStatus,
                        isSelected: false,
                        navigationStyle: .push,
                        wrapWorkspaceTitles: false,
                        selectWorkspace: { id in
                            selectWorkspace(id)
                            dismiss()
                        },
                        renameWorkspace: nil,
                        setPinned: nil
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 36, bottom: 4, trailing: 12))
                }
            }
        }
    }

    /// A connect-on-tap closure for a non-connected instance. `nil` when the
    /// instance is the connected device's own running build (nothing to connect)
    /// or advertises no reachable route.
    private func connectClosure(for capture: DeviceTreeInstanceCapture) -> (() -> Void)? {
        guard capture.hasReachableRoute else { return nil }
        let store = store
        return {
            Task {
                await store.connectToRegistryInstance(
                    device: RegistryDevice(
                        deviceId: capture.deviceId,
                        platform: "mac",
                        displayName: capture.displayName,
                        lastSeenAt: .distantPast,
                        instances: []
                    ),
                    instance: RegistryAppInstance(
                        tag: capture.tag,
                        routes: capture.routes,
                        lastSeenAt: .distantPast
                    )
                )
            }
        }
    }

    /// Whether this instance is the build the live connection currently targets,
    /// matched by route identity (the live `activeRoute` endpoint appears in this
    /// instance's routes). Used to attribute the live workspace list to exactly
    /// one tag on a multi-tag device. Returns `false` when not connected or the
    /// live route is not a host/port endpoint.
    private func instanceMatchesActiveRoute(_ instance: RegistryAppInstance) -> Bool {
        guard store.connectionState == .connected,
              case let .hostPort(liveHost, livePort)? = store.activeRoute?.endpoint else {
            return false
        }
        let normalizedLiveHost = MobileShellRouteAuthPolicy.normalizedManualHost(liveHost) ?? liveHost
        return instance.routes.contains { route in
            guard case let .hostPort(host, port) = route.endpoint else { return false }
            let normalizedHost = MobileShellRouteAuthPolicy.normalizedManualHost(host) ?? host
            return normalizedHost == normalizedLiveHost && port == livePort
        }
    }

    private func deviceExpansionID(_ device: RegistryDevice) -> String {
        "device:\(device.deviceId)"
    }

    private func instanceExpansionID(device: RegistryDevice, instance: RegistryAppInstance) -> String {
        "instance:\(device.deviceId):\(instance.tag)"
    }

    private func setExpanded(_ id: String, _ expanded: Bool) {
        var store = expansion
        store.setExpanded(id, expanded)
        expandedStorage = store.storage
    }
}

/// The immutable connect payload for one instance, captured out of the
/// `@Observable` store so the row's action closure never holds a store reference.
private struct DeviceTreeInstanceCapture {
    let deviceId: String
    let displayName: String?
    let tag: String
    let routes: [CmxAttachRoute]

    var hasReachableRoute: Bool { !routes.isEmpty }
}
#endif

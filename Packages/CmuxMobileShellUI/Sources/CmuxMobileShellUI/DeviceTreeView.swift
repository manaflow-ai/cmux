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
    /// Display preferences (title wrapping, preview line count) shared with the
    /// flat workspace list, read here at the snapshot boundary and passed down
    /// as values so tree workspace rows render identically to flat-list rows.
    @Environment(MobileDisplaySettings.self) private var displaySettings

    /// Persisted expansion shape, encoded as a newline-separated id string.
    @AppStorage("cmux.mobile.deviceTree.expanded") private var expandedStorage = ""
    @State private var isRefreshing = false
    /// The active workspace-row filter (All / Unread), the same shared model the
    /// flat list uses, applied to every expanded instance's workspace leaves.
    @State private var filter: MobileWorkspaceListFilter = .all

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
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.string("mobile.deviceTree.title", defaultValue: "Devices"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    WorkspaceListFilterMenu(filter: $filter)
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
        }
        .accessibilityIdentifier("MobileDeviceTree")
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
        // Live status only exists for the connected device. Every other device
        // is described by live presence from the heartbeat service (online /
        // offline within the missed-heartbeat window) when available, falling
        // back to the registry "last seen" hint when presence has no record.
        // The live *tag* on a multi-tag device is identified by route match (see
        // instanceMatchesActiveRoute), so per-instance liveness is correct.
        let liveStatus: MobileMacConnectionStatus? = isConnectedDevice ? store.macConnectionStatus : nil
        let presence: DeviceTreePresence? = store.presenceMap.deviceSummary(deviceId: device.deviceId)
            .map { $0.online ? .online : .offline(lastSeenAt: $0.lastSeenAt) }

        Section {
            DeviceTreeDeviceRow(
                device: DeviceTreeDeviceSnapshot(
                    deviceId: device.deviceId,
                    title: device.title,
                    platform: device.platform,
                    lastSeenAt: device.lastSeenAt,
                    instanceCount: device.instances.count,
                    isConnected: isConnectedDevice,
                    liveStatus: liveStatus,
                    presence: presence
                ),
                isExpanded: expansion.isExpanded(deviceExpansionID(device)),
                setExpanded: { expanded in setExpanded(deviceExpansionID(device), expanded) }
            )

            if expansion.isExpanded(deviceExpansionID(device)) {
                ForEach(device.instances) { instance in
                    instanceRows(
                        device: device,
                        instance: instance,
                        isConnectedDevice: isConnectedDevice
                    )
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
        let allWorkspaces = isActiveInstance ? store.workspaces : []
        // The same shared row filter the flat list applies; the instance row's
        // workspace count keeps describing the build (all workspaces), only the
        // visible leaves narrow.
        let workspaces = allWorkspaces.filter { filter.matches($0) }
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
                workspaceCount: allWorkspaces.count,
                isActiveInstance: isActiveInstance
            ),
            isExpanded: expansion.isExpanded(expansionID),
            setExpanded: { expanded in setExpanded(expansionID, expanded) },
            connect: connect
        )

        if expansion.isExpanded(expansionID) {
            if workspaces.isEmpty {
                if filter.isActive && !allWorkspaces.isEmpty {
                    // The filter (not the build) emptied the leaves; offer the
                    // shared way back instead of the connect placeholder.
                    WorkspaceListFilterEmptyRow(filter: filter) { filter = .all }
                } else {
                    DeviceTreeWorkspacePlaceholderRow(
                        isActiveInstance: isActiveInstance,
                        hasRoutes: instance.hasRoutes,
                        connect: connect
                    )
                }
            } else {
                ForEach(workspaces) { workspace in
                    WorkspaceNavigationRow(
                        workspace: workspace,
                        connectionStatus: store.macConnectionStatus,
                        isSelected: false,
                        navigationStyle: .sidebar,
                        wrapWorkspaceTitles: displaySettings.wrapWorkspaceTitles,
                        previewLineLimit: displaySettings.workspacePreviewLineCount,
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

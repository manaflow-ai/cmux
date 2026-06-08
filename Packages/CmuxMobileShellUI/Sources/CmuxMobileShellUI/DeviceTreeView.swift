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

    private var expansion: DeviceTreeExpansionStore {
        DeviceTreeExpansionStore(storage: expandedStorage)
    }

    /// Devices the phone can attach to (mac/linux/windows hosts). The phone never
    /// controls itself, so an `ios` row is filtered out rather than shown as a
    /// tappable, dead host.
    private var controllableDevices: [RegistryDevice] {
        store.registryDevices.filter(\.isControllableHost)
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
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.done", defaultValue: "Done")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("MobileDeviceTreeDone")
                }
            }
            .refreshable {
                await store.loadRegistryDevices()
            }
            .task {
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
        // Live status only exists for the connected device; others are described
        // by their registry "last seen" (best-effort liveness, no active ping).
        // TODO(device-tree): no per-host reachability ping yet for non-connected
        // devices, and the attach ticket carries no tag, so we cannot mark which
        // tag on a multi-tag device is live — only the connected device overall.
        // Surface a real ping + per-tag liveness once the host advertises it.
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
        // The connected device's live workspaces belong to whatever tag is
        // actually running there; since the ticket has no tag, attribute the live
        // workspace list to the connected device's instances. With a single
        // instance this is exact; the multi-tag case is the TODO above.
        let workspaces = isConnectedDevice ? store.workspaces : []
        let captured = DeviceTreeInstanceCapture(
            deviceId: device.deviceId,
            displayName: device.displayName,
            tag: instance.tag,
            routes: instance.routes
        )

        DeviceTreeInstanceRow(
            instance: DeviceTreeInstanceSnapshot(
                tag: instance.tag,
                lastSeenAt: instance.lastSeenAt,
                hasRoutes: instance.hasRoutes,
                workspaceCount: workspaces.count,
                isConnectedDevice: isConnectedDevice
            ),
            isExpanded: expansion.isExpanded(expansionID),
            setExpanded: { expanded in setExpanded(expansionID, expanded) },
            connect: connectClosure(for: captured)
        )

        if expansion.isExpanded(expansionID) {
            if workspaces.isEmpty {
                DeviceTreeWorkspacePlaceholderRow(
                    isConnectedDevice: isConnectedDevice,
                    hasRoutes: instance.hasRoutes,
                    connect: connectClosure(for: captured)
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

import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

/// Device rows for the Cloud-style outline: every `.device` machine the
/// catalog knows, as the same machine → Workspaces → terminals shape a cloud
/// machine gets (``CloudTreeNodeBuilder/cloudChildren``), headed by a presence
/// row instead of a fleet row.
extension CloudTreeNodeBuilder {
    /// Online devices first, then by name, then by tag, so the row order is
    /// stable while presence flips and two builds on one Mac stay adjacent.
    static func orderedDeviceInfos(_ machines: [SurfaceMachineInfo]) -> [SurfaceMachineInfo] {
        machines
            .filter { $0.id.isDevice }
            .sorted { lhs, rhs in
                let lhsOnline = CloudTreeDeviceRow.isOnline(presence: lhs.presence, linkState: lhs.linkState)
                let rhsOnline = CloudTreeDeviceRow.isOnline(presence: rhs.presence, linkState: rhs.linkState)
                if lhsOnline != rhsOnline { return lhsOnline }
                let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if byName != .orderedSame { return byName == .orderedAscending }
                return lhs.id.rawValue < rhs.id.rawValue
            }
    }

    /// The device machine rows, optionally under one "Devices" section header
    /// (the shape the Cloud tab uses once devices merge into it).
    static func deviceNodes(
        snapshot: SurfaceCatalogSnapshot,
        projectionIndex: LocalProjectionIndex,
        grouped: Bool,
        section: CloudTreeDevicesSection = .init()
    ) -> [CloudTreeNode] {
        let infos = section.discoveryEnabled ? orderedDeviceInfos(snapshot.machines) : []
        let resourcesByMachine = Dictionary(grouping: snapshot.resources, by: \.machine)
        let rows = infos.map { info in
            deviceNode(
                info: info, resources: resourcesByMachine[info.id] ?? [],
                snapshot: snapshot, projectionIndex: projectionIndex
            )
        }
        guard grouped else { return rows }
        var header = section
        header.count = rows.count
        return [CloudTreeNode(
            id: devicesSectionNodeID,
            kind: .devicesSection(header),
            children: rows + [CloudTreeNode(
                id: "devices-section/empty",
                kind: .devicesEmpty(header)
            )]
        )]
    }

    static let devicesSectionNodeID = "devices-section"

    static func deviceNode(
        info: SurfaceMachineInfo,
        resources: [SurfaceResource],
        snapshot: SurfaceCatalogSnapshot,
        projectionIndex: LocalProjectionIndex
    ) -> CloudTreeNode {
        guard let instance = info.id.deviceInstance else {
            preconditionFailure("deviceNode requires a device machine, got \(info.id)")
        }
        let row = CloudTreeDeviceRow(
            instance: instance,
            // The catalog name is tag-qualified for CLI readers; the row shows
            // the tag on its own, so the name goes back to the Mac's own.
            name: CloudTreeDeviceRow.baseName(from: info.name, instance: instance),
            presence: info.presence,
            linkState: info.linkState,
            linkError: info.linkError,
            workspaceCount: info.remoteWorkspaces?.count ?? 0,
            terminalCount: resources.filter { $0.kind == .terminal }.count
        )
        // Another Mac publishes no Cloud VM telemetry, so it has no fleet
        // snapshot and its row carries no Resources group.
        let children = cloudChildren(
            machine: info.id,
            machineSnapshot: nil,
            info: info,
            snapshot: snapshot,
            projectionIndex: projectionIndex,
            resourceNodeBuilder: CloudTreeMachineResourceNodeBuilder(),
            now: .now,
            machineResources: resources
        )
        return CloudTreeNode(
            id: nodeID(machine: info.id),
            kind: .device(row),
            children: row.canCreateWorkspacesAndTerminals ? children : children.filter {
                if case .placeholder = $0.kind { return true }
                return false
            }
        )
    }
}

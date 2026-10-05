import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

extension CloudTreeNodeBuilder {
    static func nodes(
        machines: [MachineSnapshot],
        pendingCreates: [MachineCreateOperation] = [],
        adoptedOperationIDs: [String: UUID] = [:],
        snapshot: SurfaceCatalogSnapshot,
        localWorkspaces: [CloudTreeLocalWorkspace],
        unreadTerminalIDs: [String: Set<String>] = [:],
        /// Pin state supplied by the account-scoped machine store for rows that
        /// are present only in the catalog during a fleet refresh.
        pinnedMachineIDs: Set<String> = [],
        includeLocalMachine: Bool = CloudTreeNodeBuilder.includesLocalMachine,
        source: CloudTreeMachineSource = .cloud,
        devicesSection: CloudTreeDevicesSection = .init(),
        coderouterAccounts: [CloudTreeNode.CoderouterAccount] = [],
        showsCloudVPNWarning: Bool = false,
        canCreateCloudMachine: Bool = false,
        cloudMachinesUsage: CloudMachinesUsage? = nil,
        cloudMachinesRefresh: CloudTreeSectionRefresh? = nil,
        now: Date = .now,
        resourceNodeBuilder: CloudTreeMachineResourceNodeBuilder = .init()
    ) -> [CloudTreeNode] {
        let projectionIndex = LocalProjectionIndex(snapshot: snapshot, unreadTerminalIDs: unreadTerminalIDs)
        var identities = adoptedOperationIDs
        for operation in pendingCreates where !operation.request.isBaseSetup &&
            (operation.isRunning || operation.isReconciling) {
            if let id = operation.createdMachineID ?? operation.reconcilingMachineID, identities[id] == nil {
                identities[id] = operation.id
            }
        }
        var nodes: [CloudTreeNode] = []
        guard source.includesCloudMachines else {
            // The Devices tab: other Macs only, no fleet, no This Mac.
            return deviceNodes(snapshot: snapshot, projectionIndex: projectionIndex, grouped: false, section: devicesSection)
        }
        if includeLocalMachine, let local = snapshot.machines.first(where: { $0.id.isLocal }) {
            nodes.append(localMachineNode(
                info: local,
                snapshot: snapshot,
                localWorkspaces: localWorkspaces,
                projectionIndex: projectionIndex
            ))
        }
        for operation in pendingCreates where !operation.isSuperseded(by: machines, catalogMachines: snapshot.machines) {
            nodes.append(CloudTreeNode(id: nodeID(pendingCreate: operation.id), kind: .pendingMachine(operation)))
        }
        let infoByMachine = Dictionary(snapshot.machines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        for machine in machines {
            seen.insert(machine.id)
            let info = infoByMachine[.cloud(machine.id)]
            let section = resourceNodeBuilder.section(machine, now)
            let stableID = identities[machine.id].map { nodeID(pendingCreate: $0) }
                ?? nodeID(machine: .cloud(machine.id))
            nodes.append(CloudTreeNode(
                id: stableID,
                kind: .machine(machine, info),
                children: cloudChildren(
                    machine: .cloud(machine.id),
                    machineSnapshot: machine,
                    info: info,
                    snapshot: snapshot,
                    projectionIndex: projectionIndex,
                    resourceNodeBuilder: .init(section: { _, _ in section }),
                    now: now,
                    showsCloudVPNWarning: showsCloudVPNWarning
                ),
                // A machine pin is explicit sidebar priority, stamped by the panel;
                // organization only pins the organizable rows below a machine.
                isPinned: machine.isPinned || pinnedMachineIDs.contains(machine.id)
            ))
            nodes.last?.resourceSection = section
        }
        // Include catalog-only machines so their surfaces remain reachable during fleet refresh.
        // Device machines have no cloud id and are never fleet rows.
        for info in snapshot.machines where !info.id.isLocal {
            guard let id = info.id.cloudMachineID, !seen.contains(id) else { continue }
            let catalogOnlyConnecting = machines.isEmpty && info.linkState == .connecting
            let placeholderSnapshot = MachineSnapshot(
                id: id,
                provider: "",
                image: info.image ?? "",
                isDesktop: info.hasDesktop,
                activity: MachineSnapshotBuilder.activity(fromStatus: info.status),
                createdAt: nil,
                label: info.name == id ? nil : info.name
            )
            let section = resourceNodeBuilder.section(placeholderSnapshot, now)
            nodes.append(CloudTreeNode(
                id: identities[id].map { nodeID(pendingCreate: $0) }
                    ?? nodeID(machine: info.id),
                kind: .machine(placeholderSnapshot, info),
                children: cloudChildren(
                    machine: info.id,
                    machineSnapshot: catalogOnlyConnecting ? nil : placeholderSnapshot,
                    info: info,
                    snapshot: snapshot,
                    projectionIndex: projectionIndex,
                    resourceNodeBuilder: .init(section: { _, _ in section }),
                    now: now,
                    showsCloudVPNWarning: showsCloudVPNWarning
                ),
                isPinned: pinnedMachineIDs.contains(id)
            ))
            if !catalogOnlyConnecting {
                nodes.last?.resourceSection = section
            }
        }
        if source.groupsDevicesUnderSection {
            let cloudChildren = nodes.isEmpty
                ? [CloudTreeNode(
                    id: "cloud-machines-section/empty",
                    kind: .placeholder(
                        machine: .cloud("cloud-machines-section"),
                        CloudTreePlaceholder(
                            text: String(localized: "machines.empty.none", defaultValue: "No cloud machines yet"),
                            style: .empty
                        )
                    )
                )]
                : nodes
            nodes = [CloudTreeNode(
                id: "cloud-machines-section",
                kind: .cloudMachinesSection(
                    canCreateMachine: canCreateCloudMachine, usage: cloudMachinesUsage, refresh: cloudMachinesRefresh
                ),
                children: cloudChildren
            )]
        }
        if source.includesDevices {
            nodes.append(contentsOf: deviceNodes(
                snapshot: snapshot,
                projectionIndex: projectionIndex,
                grouped: source.groupsDevicesUnderSection,
                section: devicesSection
            ))
        }
        // Keep CodeRouter immediately below My Devices so account management
        // stays alongside the two account-scoped machine sections.
        var coderouterChildren = coderouterAccounts.map { account in
            CloudTreeNode(
                id: "coderouter-section/account/\(account.id)",
                kind: .coderouterAccount(account)
            )
        }
        if coderouterChildren.isEmpty {
            coderouterChildren.append(CloudTreeNode(id: "coderouter-section/empty", kind: .coderouterEmpty))
        }
        coderouterChildren.append(CloudTreeNode(id: "coderouter-section/add-account", kind: .coderouterAddAccount))
        nodes.append(CloudTreeNode(
            id: "coderouter-section",
            kind: .coderouterSection,
            // Account rows are snapshots. Credentials never enter the tree.
            children: coderouterChildren
        ))
        return nodes
    }
}

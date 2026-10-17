import Foundation

/// Machine workspaces that cmux creates for its own plumbing and never shows.
///
/// Link delivery (`CloudEnvDelivery`, `CloudFileDelivery`) runs its receiver
/// (`cmux env receive`, `cmux file receive`) in a temporary, empty machine
/// workspace named `<title> <UUID>` and closes it when the delivery ends. While it
/// exists it is an ordinary daemon workspace, so any reader of the graph would
/// otherwise list it in the tree, count it, adopt it as a new machine's starter
/// workspace (it is the newest and usually the daemon's focused one), or open it
/// as a local workspace titled `cmux env 2EDB0839-…`.
///
/// This predicate is the one definition of such a workspace. The delivery code
/// names its workspace with ``internalReceiverWorkspaceName(title:id:clientID:)`` and every
/// catalog reader goes through ``SurfaceCatalogSnapshot/hidingInternalReceiverWorkspaces()``.
extension SurfaceRemoteWorkspace {
    /// Receiver titles that mark an internal workspace. The terminal inside keeps
    /// the bare title; the workspace adds a UUID so it can never collide with a
    /// workspace a person named `cmux env`.
    public static let environmentReceiverTitle = "cmux env"
    public static let fileReceiverTitle = "cmux file"
    static let internalReceiverTitles = [environmentReceiverTitle, fileReceiverTitle]

    /// The name a link-delivery receiver workspace is created with.
    public static func internalReceiverWorkspaceName(title: String, id: UUID = UUID(), clientID: String? = nil) -> String {
        if let clientID, !clientID.isEmpty {
            return "\(title) \(clientID) \(id.uuidString)"
        }
        return "\(title) \(id.uuidString)"
    }

    /// Whether `name` is a receiver workspace name: a reserved title, one space,
    /// and a UUID, exactly. `cmux env staging` stays an ordinary workspace.
    public static func isInternalReceiverWorkspaceName(_ name: String) -> Bool {
        internalReceiverTitles.contains { title in
            let prefix = title + " "
            guard name.hasPrefix(prefix) else { return false }
            let components = name.dropFirst(prefix.count).split(separator: " ")
            return (components.count == 1 || components.count == 2)
                && UUID(uuidString: String(components.last!)) != nil
        }
    }

    /// Whether this workspace is internal plumbing that no reader may show or adopt.
    public var isInternalReceiver: Bool { Self.isInternalReceiverWorkspaceName(name) }

    /// The client identifier embedded in a receiver name, when this process created it.
    /// Older receiver names have no client identifier and are intentionally returned as nil.
    public var internalReceiverClientID: String? {
        guard isInternalReceiver else { return nil }
        for title in Self.internalReceiverTitles {
            let prefix = title + " "
            guard name.hasPrefix(prefix) else { continue }
            let components = name.dropFirst(prefix.count).split(separator: " ")
            if components.count == 2 { return String(components[0]) }
        }
        return nil
    }

    /// The receiver workspaces a link sweep may close: every internal receiver on the
    /// machine, sorted by id, once this Mac has no link delivery of its own in flight.
    ///
    /// A receiver whose delivery ended without cleanup (the app quit, the link
    /// dropped before the close landed) is hidden from every reader, so nothing else
    /// would ever remove it. While a delivery of this session is running, its
    /// receiver could already be in the graph before the delivery knows its id, so
    /// the sweep waits for the next connect instead of guessing.
    public static func leakedInternalReceiverIDs(
        in workspaces: [SurfaceRemoteWorkspace],
        deliveriesInFlight: Int,
        clientID: String? = nil
    ) -> [String] {
        guard deliveriesInFlight == 0 else { return [] }
        return workspaces.filter { workspace in
            workspace.isInternalReceiver && (clientID == nil || workspace.internalReceiverClientID == clientID)
        }.map(\.id).sorted()
    }
}

extension SurfaceCatalogSnapshot {
    /// The snapshot without internal receiver workspaces, the resources that live
    /// only in them, and any projection into them. Resources that also have a view
    /// in an ordinary workspace keep that view.
    public func hidingInternalReceiverWorkspaces() -> SurfaceCatalogSnapshot {
        var hiddenIDs: [SurfaceMachineID: Set<String>] = [:]
        func collect(_ workspace: SurfaceRemoteWorkspace, on machine: SurfaceMachineID) {
            if workspace.isInternalReceiver { hiddenIDs[machine, default: []].insert(workspace.id) }
        }
        for info in machines {
            for workspace in info.remoteWorkspaces ?? [] { collect(workspace, on: info.id) }
        }
        for resource in resources {
            for workspace in resource.remoteWorkspaces { collect(workspace, on: resource.machine) }
        }
        guard !hiddenIDs.isEmpty else { return self }
        func hidden(_ machine: SurfaceMachineID, _ workspaceID: String) -> Bool {
            hiddenIDs[machine]?.contains(workspaceID) == true
        }

        var result = self
        result.machines = machines.map { info in
            guard let workspaces = info.remoteWorkspaces else { return info }
            var info = info
            info.remoteWorkspaces = workspaces.filter { !hidden(info.id, $0.id) }
            return info
        }
        var removedResources = Set<SurfaceResourceID>()
        result.resources = resources.compactMap { resource in
            let workspaces = resource.remoteWorkspaces
            guard workspaces.contains(where: { hidden(resource.machine, $0.id) }) else { return resource }
            guard let views = resource.remoteViews else {
                removedResources.insert(resource.id)
                return nil
            }
            var resource = resource
            let kept = views.filter { !hidden(resource.machine, $0.workspace.id) }
            guard !kept.isEmpty else {
                removedResources.insert(resource.id)
                return nil
            }
            resource.remoteViews = kept
            resource.remoteWorkspace = kept.first?.workspace
            return resource
        }
        result.projections = projections.filter { projection in
            !removedResources.contains(projection.resource)
                && projection.remoteWorkspaceID.map { hidden(projection.resource.machine, $0) } != true
        }
        if let pending = pendingWorkspaceCreations {
            var filtered: [SurfaceMachineID: [String: UUID]] = [:]
            for (machine, byWorkspace) in pending {
                let kept = byWorkspace.filter { !hidden(machine, $0.key) }
                if !kept.isEmpty { filtered[machine] = kept }
            }
            result.pendingWorkspaceCreations = filtered.isEmpty ? nil : filtered
        }
        return result
    }
}

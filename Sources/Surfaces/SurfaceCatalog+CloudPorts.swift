import CmuxFoundation
import Foundation

extension SurfaceResourceID {
    /// The numeric port encoded by the canonical cloud forwarded-port identity.
    /// Snapshot browser views that visit localhost are normalized to this key so
    /// the machine port and its workspace row share one resource identity.
    var forwardedPort: Int? {
        guard kind == .browser, key.hasPrefix("port:") else { return nil }
        let value = key.dropFirst("port:".count)
        guard let port = Int(value), (1...65_535).contains(port) else { return nil }
        guard key == SurfaceResourceID.portKey(port) else { return nil }
        return port
    }

    /// Whether this id is the machine-level forwarded-port resource.
    var isForwardedPort: Bool { forwardedPort != nil }
}

extension SurfaceCatalog {
    /// Localized destination error shared by the sidebar and socket open paths.
    nonisolated static func portDestinationUnavailableMessage(machine: SurfaceMachineID) -> String {
        String(
            format: String(
                localized: "cloudTree.port.noLocalWorkspace",
                defaultValue: "No local workspace is showing %@; select a workspace and retry."
            ),
            machine.rawValue
        )
    }

    /// Localized explanation used by both the sidebar and socket port-open paths.
    nonisolated static func portPreviewUnavailableMessage(machineID: String) -> String {
        String(
            format: String(
                localized: "cloudTree.port.unsupported",
                defaultValue: "%@’s provider cannot open machine ports as previews; reach the service from inside the machine with `cmux vm exec %@ -- …`."
            ),
            machineID,
            machineID
        )
    }

    /// Opens one canonical cloud port through the catalog's provider and
    /// projection path.
    ///
    /// The resource is inserted when a caller names a port before the next
    /// discovery pass. Its identity is always `<machine>/browser/port:<n>`;
    /// refreshing the provider can therefore replace its metadata without
    /// changing the row, projection, or CLI address.
    @discardableResult
    func openCloudPort(
        machine: SurfaceMachineID,
        port: Int,
        into destination: SurfaceDestination,
        focus: Bool,
        reuseExisting: Bool
    ) async throws -> (projection: SurfaceProjection, reused: Bool) {
        guard case .cloud = machine, (1...65_535).contains(port) else {
            throw SurfaceCatalogError.unsupported(
                String(localized: "cloudTree.port.invalidMachine", defaultValue: "Ports can only be opened on a cloud machine.")
            )
        }
        guard let provider = provider(for: machine) else {
            throw SurfaceCatalogError.noProvider(machine)
        }
        guard provider.supportsPortPreviews else {
            throw SurfaceCatalogError.unsupported(Self.portPreviewUnavailableMessage(machineID: machine.rawValue))
        }

        let id = SurfaceResourceID(machine: machine, kind: .browser, key: SurfaceResourceID.portKey(port))
        let directURL = provider.info.privateAddress.map {
            CmuxInternalHostnames.directPortURL(privateAddress: $0, port: port)
        }
        if var existing = resources[id] {
            // A machine address can be assigned after the first catalog pass.
            // Refresh the URL in place while preserving workspace/view metadata.
            if existing.port != port || existing.url != directURL {
                existing.port = port
                existing.url = directURL
                upsert(existing)
            }
        } else {
            upsert(CmuxTuiSnapshotParser.portBrowser(machine: machine, port: port, directURL: directURL))
        }
        return try await project(
            id,
            into: destination,
            focus: focus,
            reuseExisting: reuseExisting
        )
    }

    /// Chooses the local workspace that already shows the cloud machine's
    /// resources, falling back to the caller's captured workspace. When a
    /// resource carries remote-workspace membership, only sibling resources in
    /// those remote workspaces participate in the vote; this keeps a port from
    /// following an unrelated machine workspace.
    func preferredLocalWorkspaceID(
        for resourceID: SurfaceResourceID,
        fallback: UUID?
    ) -> UUID? {
        // Keep the lookup useful when a refresh retired the resource after a row
        // was rendered: a live projection still gives us an unambiguous owner.
        let resource = resources[resourceID]
        if let resource {
            return preferredLocalWorkspaceID(for: resource, fallback: fallback)
        }
        return projections.first(where: { $0.resource == resourceID })?.workspaceID ?? fallback
    }

    /// Resolves the local workspace for a value captured from a tree snapshot.
    /// Callers that begin an asynchronous open use this overload before yielding
    /// so a later catalog replacement cannot erase the remote-workspace context.
    func preferredLocalWorkspaceID(
        for resource: SurfaceResource,
        fallback: UUID?
    ) -> UUID? {
        let machine = resource.machine
        let remoteWorkspaceIDs = Set(resource.remoteWorkspaces.map(\.id))
        guard !remoteWorkspaceIDs.isEmpty else {
            // A machine-pool port has no remote workspace owner. Never infer one
            // from unrelated projections on the same machine.
            return projections.first(where: { $0.resource == resource.id })?.workspaceID ?? fallback
        }
        var relatedIDs = Set([resource.id])
        relatedIDs.formUnion(resources.values.compactMap { candidate -> SurfaceResourceID? in
            guard candidate.machine == machine else { return nil }
            return candidate.remoteWorkspaces.contains { remoteWorkspaceIDs.contains($0.id) }
                ? candidate.id
                : nil
        })

        var projectionCounts: [UUID: Int] = [:]
        for projection in projections where relatedIDs.contains(projection.resource) {
            projectionCounts[projection.workspaceID, default: 0] += 1
        }
        return projectionCounts
            .sorted {
                lhs.value != rhs.value
                    ? lhs.value > rhs.value
                    : lhs.key.uuidString < rhs.key.uuidString
            }
            .first?.key ?? fallback
    }

    /// Keeps a port that was added or reopened while a provider refresh was
    /// suspended. `replaceResources` is intentionally authoritative for the
    /// provider snapshot, but it must not erase a just-started open (or a pane
    /// that is still live) between the scan and publication of that snapshot.
    func preservingConcurrentPortResources(
        _ refreshed: [SurfaceResource],
        on machine: SurfaceMachineID,
        since previous: [SurfaceResource]
    ) -> [SurfaceResource] {
        let refreshedIDs = Set(refreshed.map(\.id))
        let previousIDs = Set(previous.map(\.id))
        var result = refreshed
        for candidate in snapshot.resources(on: machine)
        where candidate.id.isForwardedPort && !refreshedIDs.contains(candidate.id) {
            let wasAddedDuringRefresh = !previousIDs.contains(candidate.id)
            let remainsProjected = !projections(of: candidate.id).isEmpty
            guard wasAddedDuringRefresh || remainsProjected else { continue }
            result.append(candidate)
        }
        return result
    }
}

extension CmuxTuiSurfaceProvider {
    /// Converts one port-probe result into a complete scan. A non-zero exit is
    /// incomplete (the command or transport was unavailable); a successful
    /// header-only listing is authoritative and intentionally returns `[]`.
    nonisolated static func ports(from result: VMExecResult) -> [Int]? {
        guard result.exitCode == 0 else { return nil }
        return CmuxTuiSnapshotParser.listeningPorts(fromSocketListing: result.stdout)
            .filter { !CmuxTuiSnapshotParser.internalPorts.contains($0) }
    }

    /// Reconciles one machine's port scan with its prior catalog values.
    /// `scannedPorts == nil` means the probe was unavailable and preserves the
    /// last known canonical resources; an empty array is an authoritative scan
    /// and retires them. Existing resources retain workspace metadata while a
    /// successful scan refreshes their direct URL.
    nonisolated static func portResources(
        machine: SurfaceMachineID,
        scannedPorts: [Int]?,
        previousResources: [SurfaceResource],
        privateAddress: String?
    ) -> [SurfaceResource] {
        let previous = Dictionary(
            previousResources.filter { $0.id.isForwardedPort },
            uniquingKeysWith: { first, _ in first }
        )
        guard let scannedPorts else {
            return previous.values.map { resource in
                var refreshed = resource
                if let port = resource.forwardedPort {
                    refreshed.port = port
                    refreshed.url = privateAddress.map {
                        CmuxInternalHostnames.directPortURL(privateAddress: $0, port: port)
                    }
                }
                return refreshed
            }.sorted { $0.id.key < $1.id.key }
        }

        var seen = Set<Int>()
        return scannedPorts
            .filter { (1...65_535).contains($0) && seen.insert($0).inserted }
            .sorted()
            .map { port in
                let id = SurfaceResourceID(machine: machine, kind: .browser, key: SurfaceResourceID.portKey(port))
                if var existing = previous[id] {
                    existing.port = port
                    existing.url = privateAddress.map {
                        CmuxInternalHostnames.directPortURL(privateAddress: $0, port: port)
                    }
                    return existing
                }
                let directURL = privateAddress.map {
                    CmuxInternalHostnames.directPortURL(privateAddress: $0, port: port)
                }
                return CmuxTuiSnapshotParser.portBrowser(machine: machine, port: port, directURL: directURL)
            }
    }

    /// Reconciles a valid cmux-tui snapshot with the machine-level port pool.
    ///
    /// A daemon browser whose URL points at localhost is another view of the
    /// machine port, not a second resource. It is folded into the canonical
    /// `browser/port:<n>` identity so the same value can be projected in the
    /// machine's Ports group and under every remote workspace that contains a
    /// view. A valid snapshot is authoritative for workspace membership, while
    /// the port pool remains authoritative for discovery; an incomplete
    /// snapshot never calls this function and therefore preserves the prior
    /// metadata in the caller.
    nonisolated static func mergeSnapshotResources(
        pool: [SurfaceResource],
        parsed: [SurfaceResource],
        privateAddress: String?
    ) -> [SurfaceResource] {
        let priorPorts = Dictionary(
            pool.filter { $0.id.isForwardedPort },
            uniquingKeysWith: { first, _ in first }
        )
        var parsedPortIDs = Set<SurfaceResourceID>()
        var parsedResources: [SurfaceResource] = []
        var portIndexes: [SurfaceResourceID: Int] = [:]

        for resource in parsed {
            guard resource.kind == .browser,
                  let port = resource.port,
                  (1...65_535).contains(port) else {
                parsedResources.append(resource)
                continue
            }

            let id = SurfaceResourceID(
                machine: resource.machine,
                kind: .browser,
                key: SurfaceResourceID.portKey(port)
            )
            parsedPortIDs.insert(id)
            if let index = portIndexes[id] {
                var merged = parsedResources[index]
                mergeRemoteViews(from: resource, into: &merged)
                parsedResources[index] = merged
                continue
            }

            var canonical = priorPorts[id]
                ?? CmuxTuiSnapshotParser.portBrowser(machine: resource.machine, port: port)
            canonical.id = id
            canonical.port = port
            // A fresh private address wins. If the address is absent, clear the
            // direct URL so an address withdrawal cannot leave a stale link in
            // the catalog; the provider endpoint cache remains independent.
            if let privateAddress {
                canonical.url = CmuxInternalHostnames.directPortURL(privateAddress: privateAddress, port: port)
            } else {
                canonical.url = nil
            }
            // Keep the daemon tab's useful title for the workspace pointer. The
            // Ports row derives its label from `url`/`port`, so this does not
            // change the machine-level port presentation.
            if !resource.title.isEmpty {
                canonical.title = resource.title
            }
            // Membership comes from this snapshot, never from the prior pass.
            canonical.remoteWorkspace = nil
            canonical.remoteViews = nil
            mergeRemoteViews(from: resource, into: &canonical)
            portIndexes[id] = parsedResources.count
            parsedResources.append(canonical)
        }

        // Ports that were discovered by `ss` but are not represented by a
        // daemon browser remain machine-pool resources. Their previous view
        // metadata is cleared because this snapshot is authoritative.
        let remainingPool = pool.filter { resource in
            guard resource.id.isForwardedPort else { return true }
            return !parsedPortIDs.contains(resource.id)
        }.map { resource -> SurfaceResource in
            guard resource.id.isForwardedPort else { return resource }
            var cleared = resource
            cleared.remoteWorkspace = nil
            cleared.remoteViews = nil
            return cleared
        }

        // If the snapshot itself discovered a port that the probe missed, its
        // canonical resource is already in `parsedResources`; if it replaced a
        // pooled port, the pooled copy was removed above. Display de-duplication
        // remains the parser's existing invariant.
        return CmuxTuiSnapshotParser.mergingDisplays(pool: remainingPool, parsed: parsedResources)
    }

    /// Adds a browser's daemon view metadata to a canonical port resource while
    /// preserving the distinction between an unmodeled view list (`nil`) and a
    /// live resource with no views (`[]`).
    private nonisolated static func mergeRemoteViews(
        from source: SurfaceResource,
        into destination: inout SurfaceResource
    ) {
        if let incoming = source.remoteViews {
            var combined = destination.remoteViews ?? []
            var seen = Set(combined.map { "\($0.tabID)|\($0.workspace.id)" })
            for view in incoming where seen.insert("\(view.tabID)|\(view.workspace.id)").inserted {
                combined.append(view)
            }
            destination.remoteViews = combined
            destination.remoteWorkspace = combined.first?.workspace
        } else if destination.remoteViews == nil {
            destination.remoteWorkspace = source.remoteWorkspace
        }
    }
}

import CmuxFoundation
import Foundation

extension SurfaceResourceID {
    /// The numeric port encoded by the canonical cloud forwarded-port identity.
    /// Browser tabs that happen to visit localhost use a different provider key
    /// and therefore remain ordinary browser resources.
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
        let machine = resourceID.machine
        let remoteWorkspaceIDs = Set(resources[resourceID]?.remoteWorkspaces.map(\.id) ?? [])
        var relatedIDs = Set([resourceID])
        relatedIDs.formUnion(resources.values.compactMap { candidate -> SurfaceResourceID? in
            guard candidate.machine == machine else { return nil }
            if remoteWorkspaceIDs.isEmpty { return candidate.id }
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
}

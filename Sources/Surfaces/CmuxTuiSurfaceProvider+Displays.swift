import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import CmuxFoundation

extension CmuxTuiSurfaceProvider {
    var supportsDisplayCreation: Bool {
        // The stored machine kind predates the desktop capability contract and
        // is stale on some VMs that already have the validated runtime. The
        // display coordinator's live guest probe is the authority; retain the
        // local checks that prevent requests while asleep or detached.
        isAwake && info.hasDesktop && isRegisteredInCatalog()
    }

    var displayResources: [SurfaceResource] {
        let base: [SurfaceResource]
        if let snapshot = displayCoordinator.displaySnapshot {
            base = snapshot.displays.map { $0.resource(on: machine, address: info.privateAddress) }
        } else {
            base = [CmuxTuiSnapshotParser.display(machine: machine,
                directURL: info.privateAddress.map { Self.privateDesktopURL(privateAddress: $0) })]
        }
        // A named display carries its name everywhere it is listed or shown.
        let names = cloudState?.displayNames ?? [:]
        return base.map { resource in
            guard let name = names[resource.id.key] else { return resource }
            var named = resource
            named.title = name
            return named
        }
    }

    /// Republishes display rows and pane titles when the graph's display names
    /// change (a rename here, from another Mac, or a cleared name).
    func applyDisplayNamesIfChanged(_ state: CloudVMState) {
        let names = state.displayNames
        guard names != appliedDisplayNames else { return }
        appliedDisplayNames = names
        publishDisplays()
    }

    /// A display pane's tab shows its display's name ("Display 2" until it is
    /// renamed), not the noVNC page title, so the tab and the sidebar agree.
    func applyDisplayPaneTitles() {
        for resource in displayResources {
            for projection in catalog.projections(of: resource.id) {
                guard let workspace = Workspace.liveWorkspace(id: projection.workspaceID),
                      workspace.panelCustomTitles[projection.panelID] != resource.title else { continue }
                workspace.setPanelCustomTitle(panelId: projection.panelID, title: resource.title,
                                              source: .remote, propagateToCloud: false, catalog: catalog)
            }
        }
    }

    /// A workspace's display memberships name displays the catalog only learns
    /// from guest discovery, and memberships for unknown displays are ignored.
    /// Without this, a cloud workspace opened or restored before anything else
    /// ran discovery showed only display 1 until a later refresh. Runs once per
    /// lifecycle generation; the publish path then materializes every member.
    /// Launch-time refreshes can cancel an attempt, so each completion checks
    /// again, bounded to a few attempts per lifecycle generation.
    func discoverMemberDisplaysIfNeeded(_ state: CloudVMState?) {
        guard memberDisplayDiscovery == nil, supportsDisplayCreation, let state else { return }
        let known = Set(displayResources.map(\.id.key))
        guard state.displayMemberships.contains(where: { !known.contains($0.displayID) }) else { return }
        let generation = currentLifecycleGeneration
        if memberDisplayDiscoveryAttempts.generation != generation {
            memberDisplayDiscoveryAttempts = (generation, 0)
        }
        guard memberDisplayDiscoveryAttempts.count < Self.maxMemberDisplayDiscoveryAttempts else { return }
        memberDisplayDiscoveryAttempts.count += 1
        memberDisplayDiscovery = Task { [weak self] in
            await self?.refreshDisplays()
            guard let self else { return }
            self.memberDisplayDiscovery = nil
            guard self.isCurrentLifecycleGeneration(generation) else { return }
            self.discoverMemberDisplaysIfNeeded(self.cloudState)
        }
    }

    static let maxMemberDisplayDiscoveryAttempts = 3

    /// Only a user-requested refresh/expansion performs guest discovery. Results
    /// may publish only through the same still-authorized provider instance.
    func refreshDisplays() async {
        guard isAwake, info.hasDesktop else { return }
        let generation = currentLifecycleGeneration
        await displayCoordinator.refresh()
        // Not `isCurrentRefresh`: every machine-list poll bumps the refresh
        // generation, so a guest discovery (about 2s) that overlapped a poll was
        // discarded and member displays appeared only after a later lucky one.
        // The coordinator invalidates its own result when the VM's identity or
        // image changes; only the lifecycle has to match here.
        guard !isFeatureSuspended, isCurrentLifecycleGeneration(generation), isRegisteredInCatalog() else { return }
        publishDisplays()
    }

    func createDisplay() async throws -> SurfaceResource {
        guard supportsDisplayCreation else { throw SurfaceCatalogError.unsupported(CloudGuestDisplaySnapshot.unavailableMessage) }
        // No discovery round trip first: the create command installs the guest
        // helper itself and its reply is the full catalog, so a prior `list`
        // only added a second VM exec (about two seconds) to the first click.
        // The new display's pane needs this machine's browser carrier. Its first
        // start costs seconds (trusted-listener preparation, process launch),
        // so begin it alongside the guest exec instead of after it. The link
        // manager shares one start per machine; the pane awaits the same one.
        let links = self.links, machineID = self.machineID
        Task { _ = try? await links.browserProxy(machineID: machineID) }
        let generation = currentLifecycleGeneration
        defer {
            if isCurrentLifecycleGeneration(generation), isRegisteredInCatalog() { publishDisplays() }
        }
        let snapshot = try await displayCoordinator.create()
        guard isCurrentLifecycleGeneration(generation), isRegisteredInCatalog() else { throw CancellationError() }
        guard let display = snapshot.displays.first(where: { $0.id == snapshot.created }) else {
            throw SurfaceCatalogError.unsupported(CloudGuestDisplaySnapshot.unavailableMessage)
        }
        return display.resource(on: machine, address: info.privateAddress)
    }

    private func publishDisplays() {
        let resources = displayResources
        let desiredIDs = Set(resources.map(\.id))
        for resource in catalog.snapshot.resources(on: machine)
            where resource.kind == .display && !desiredIDs.contains(resource.id) {
            catalog.remove(resource.id, from: self)
        }
        for var resource in resources {
            // Guest discovery owns the connection, while the daemon/catalog
            // owns existing view placements. Refresh must preserve both.
            if let existing = catalog.resources[resource.id] {
                resource.remoteViews = existing.remoteViews
                resource.remoteWorkspace = existing.remoteWorkspace
            }
            catalog.upsert(resource, from: self)
        }
        catalog.notifyChange()
        applyDisplayPaneTitles()
    }

    /// The noVNC URL retains each display's own port across VM reconnects.
    nonisolated static func privateDesktopURL(privateAddress: String, port: Int = CmuxTuiSnapshotParser.desktopPort) -> String {
        CloudGuestDisplay.privateDesktopURL(privateAddress: privateAddress, port: port)
    }
}

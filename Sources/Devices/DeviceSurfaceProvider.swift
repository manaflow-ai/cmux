import CMUXMobileCore
import CmuxTerminal
import Foundation

/// Another Mac as a surface provider: its synced workspaces and terminals are
/// the resources, its presence and link state are the machine info, and a
/// projection is a manual-mirror Ghostty pane fed by ``DeviceTerminalMirrorSession``.
/// The Devices tree, drag-and-drop, `surface.catalog`, and `cmux vm tree` all
/// read this through the catalog, so a device row and a cloud row are the same
/// shape to every action path.
@MainActor
final class DeviceSurfaceProvider: SurfaceProvider {
    let instance: SurfaceDeviceInstanceID
    let link: DeviceLink
    let catalog: SurfaceCatalog
    private(set) var record: DeviceDirectoryRecord
    /// Live projections keyed by the local panel that shows them.
    var sessions: [UUID: DeviceTerminalMirrorSession] = [:]

    var machine: SurfaceMachineID { .device(instance) }
    var supportsPortPreviews: Bool { false }

    init(record: DeviceDirectoryRecord, link: DeviceLink, catalog: SurfaceCatalog) {
        instance = record.instance
        self.record = record
        self.link = link
        self.catalog = catalog
        link.onChange = { [weak self] in self?.publish() }
    }

    func update(record: DeviceDirectoryRecord) {
        self.record = record
        link.update(record: record)
        publish()
    }

    /// The pairing store changed; the link re-evaluates its grant and the row
    /// follows (a fresh pairing dials, an unpair drops the link).
    func authorizationDidChange() {
        link.authorizationDidChange()
        publish()
    }

    func stop() {
        for session in sessions.values { session.stop() }
        sessions.removeAll()
        link.stop()
    }

    // MARK: - Catalog rows

    var info: SurfaceMachineInfo {
        let state = Self.linkState(
            record: record, phase: link.phase, lastFailure: link.lastFailure, needsAuthorization: link.needsAuthorization
        )
        let workspaces = link.mirror.workspaces.hasState
            ? DeviceWorkspaceProjection(machine: machine, isLive: link.isConnected)
                .remoteWorkspaces(link.mirror.workspaces.orderedRecords)
            : nil
        return SurfaceMachineInfo(
            id: machine,
            name: record.displayName,
            status: record.isOnline || link.isConnected ? "running" : "offline",
            image: nil,
            hasDesktop: false,
            memoryMb: nil,
            diskMb: nil,
            linkState: state.linkState,
            linkError: state.linkError,
            cpuPercent: nil,
            memoryUsedMb: nil,
            diskUsedMb: nil,
            remoteWorkspaces: workspaces,
            privateAddress: nil,
            presence: record.presence
        )
    }

    /// Account trust is checked before a live link (a Mac that answers is
    /// online whatever presence says); then presence,
    /// which labels an offline Mac while a paired link keeps dialing quietly;
    /// then pairing; then the reconnect phase.
    static func linkState(
        record: DeviceDirectoryRecord,
        phase: DeviceLinkReconnectPolicy.Phase,
        lastFailure: String?,
        needsAuthorization: Bool = false
    ) -> (linkState: SurfaceLinkState, linkError: String?) {
        if record.accountTrust == .otherAccount {
            return (.unavailable, String(localized: "devices.link.otherAccount", defaultValue: "Signed in as a different account"))
        }
        if phase == .connected {
            return (.connected, nil)
        }
        if record.presenceState == .offline {
            return (.offline, nil)
        }
        switch phase {
        case .connected:
            return (.connected, nil)
        case .connecting, .waiting:
            return (.connecting, nil)
        case .blocked(let reason):
            return (.error, reason)
        case .idle:
            if record.routes.isEmpty {
                return (.unavailable, String(localized: "devices.link.noRoutes", defaultValue: "This Mac has not published a route yet."))
            }
            if record.accountTrust == .unknown {
                return (.unavailable, String(localized: "devices.link.ownerUnknown", defaultValue: "Waiting to confirm this Mac belongs to your account\u{2026}"))
            }
            if needsAuthorization {
                return (.unavailable, String(localized: "devices.link.needsAuthorization", defaultValue: "Pair this Mac in Settings \u{203A} Computers to connect."))
            }
            return (.unavailable, lastFailure)
        }
    }

    func publish() {
        let projection = DeviceWorkspaceProjection(machine: machine, isLive: link.isConnected)
        let resources = projection.resources(link.mirror.workspaces.orderedRecords)
        catalog.replaceResources(resources, on: machine, info: info, from: self)
    }

    // MARK: - SurfaceProvider

    func refresh() async {
        await refresh(force: false)
    }

    func refresh(force: Bool) async {
        link.refresh()
        await link.fetchNow()
        publish()
    }

    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
        try await materialize(resource, remoteView: nil, at: destination, focus: focus)
    }

    func materialize(
        _ resource: SurfaceResource,
        remoteView: SurfaceRemoteView?,
        at destination: SurfaceDestination,
        focus: Bool
    ) async throws -> SurfaceProjection {
        guard resource.kind == .terminal else {
            throw SurfaceCatalogError.unsupported(
                String(localized: "devices.open.browserUnsupported", defaultValue: "Browsers on another Mac can\u{2019}t be opened here yet.")
            )
        }
        guard link.isConnected else { throw DeviceLinkError.notConnected }
        guard let surfaceID = UUID(uuidString: resource.id.key) else {
            throw SurfaceCatalogError.unknownResource(resource.id)
        }
        let view = remoteView ?? resource.remoteViews?.first
        guard let workspaceID = view?.workspace.id ?? resource.remoteWorkspace?.id else {
            throw SurfaceCatalogError.unavailable(resource.id, reason: String(localized: "devices.open.noWorkspace", defaultValue: "This terminal has no remote workspace."))
        }
        let session = DeviceTerminalMirrorSession(link: link, remoteWorkspaceID: workspaceID, remoteSurfaceID: surfaceID)
        let router = session.inputRouter
        let created: (workspaceID: UUID, panelID: UUID, surface: TerminalSurface)
        do {
            created = try SurfacePaneFactory.makeCloudManualMirrorPane(
                at: destination,
                focus: focus,
                onInput: { input in router.enqueue(input) },
                keyNameResolver: nil,
                onResize: { [weak session] sample in session?.apply(size: sample) },
                onRuntimeReady: { [weak session] in session?.runtimeReady() },
                onFocus: {}
            )
        } catch {
            session.stop()
            throw error
        }
        session.bind(surface: created.surface)
        sessions[created.panelID] = session
        session.start()
        Self.setInitialTitle(resource.title, panelID: created.panelID, workspaceID: created.workspaceID)
        return SurfaceProjection(
            resource: resource.id,
            workspaceID: created.workspaceID,
            panelID: created.panelID,
            remoteWorkspaceID: workspaceID,
            remoteTabID: view?.tabID
        )
    }

    /// The remote terminal's title seeds the local tab; the mirrored byte
    /// stream carries the remote shell's own title updates from then on.
    private static func setInitialTitle(_ title: String, panelID: UUID, workspaceID: UUID) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let workspace = AppDelegate.shared?.tabManagerFor(tabId: workspaceID)?.tabs.first(where: { $0.id == workspaceID }) else {
            return
        }
        workspace.setPanelCustomTitle(
            panelId: panelID,
            title: trimmed,
            source: .remote,
            propagateToRemoteTmux: false,
            propagateToCloud: false
        )
    }

    func projectionDidEnd(_ projection: SurfaceProjection) {
        sessions.removeValue(forKey: projection.panelID)?.stop()
    }

    @discardableResult
    func discardMaterialization(_ projection: SurfaceProjection) -> Bool {
        sessions.removeValue(forKey: projection.panelID)?.stop()
        SurfacePaneFactory.close(panelID: projection.panelID, in: projection.workspaceID)
        return false
    }
}

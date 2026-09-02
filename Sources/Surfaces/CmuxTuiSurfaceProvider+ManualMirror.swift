import CmuxTerminal
import CmuxRemoteSession
import Foundation

/// The native pane and its transport owner returned by cloud materialization.
struct CloudManualMirrorMaterialization {
    let workspaceID: UUID
    let panelID: UUID
    let surface: TerminalSurface
    let session: CloudTuiManualMirrorSession
}

@MainActor
extension CmuxTuiSurfaceProvider {
    /// Creates a native manual-I/O pane and attaches it to the remote PTY.
    ///
    /// The legacy tree lookup is only an identity bridge: public `term_…`
    /// resource ids intentionally hide the numeric surface id used by the raw
    /// attach stream.
    func materializeManualMirrorTerminal(
        _ resource: SurfaceResource,
        at destination: SurfaceDestination,
        focus: Bool
    ) async throws -> CloudManualMirrorMaterialization {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else {
            throw ProviderError.machineAsleep(machineID)
        }
        let remoteSurfaceID = await Self.resolveSurfaceID(
            terminalID: resource.id.key,
            socketPath: connected.socketPath,
            link: link
        )
        guard let remoteSurfaceID else {
            throw ProviderError.terminalNotCreated(
                resource.id.key
            )
        }

        let session = CloudTuiManualMirrorSession(
            machineID: machineID,
            terminalID: resource.id.key,
            remoteSurfaceID: remoteSurfaceID,
            initiallyClaimsGeometry: focus,
            onNeedsReconnect: { [weak self] in
                self?.scheduleRefresh()
            }
        )
        let inputRouter = session.inputRouter
        do {
            let created = try SurfacePaneFactory.makeCloudManualMirrorPane(
                at: destination,
                focus: focus,
                onInput: { input in inputRouter.send(input) },
                keyNameResolver: { RemoteTmuxKeyName(inputEvent: $0)?.value },
                onResize: { [weak session] sample in
                    session?.apply(size: sample)
                },
                onRuntimeReady: { [weak session] in
                    session?.runtimeReady()
                },
                onFocus: { [weak session] in
                    session?.claimGeometry()
                }
            )
            session.bind(surface: created.surface)
            // Preserve the workspace's existing notification-dismissal hook
            // while re-claiming geometry when this pane receives explicit
            // input. A cloud terminal can have more than one local projection;
            // the pane the user is typing in must be the authoritative owner.
            let existingExplicitInput = created.surface.onExplicitInput
            created.surface.onExplicitInput = { [weak session] in
                existingExplicitInput?()
                session?.claimGeometry()
            }
            manualMirrorSessions[created.panelID] = session
            session.reconnect(socketPath: connected.socketPath)
            return CloudManualMirrorMaterialization(
                workspaceID: created.workspaceID,
                panelID: created.panelID,
                surface: created.surface,
                session: session
            )
        } catch {
            session.stop()
            throw error
        }
    }

    /// Replaces a restored placeholder projection with a native manual pane.
    func reprojectManualMirror(
        resource: SurfaceResource,
        projection: SurfaceProjection,
        paneID: String
    ) async {
        do {
            let materialized = try await materializeManualMirrorTerminal(
                resource,
                at: .tab(workspaceID: projection.workspaceID, paneID: paneID, index: nil),
                focus: false
            )
            materializedPanels.insert(materialized.panelID)
            catalog.endProjections(panelID: projection.panelID)
            catalog.record(SurfaceProjection(
                resource: resource.id,
                workspaceID: materialized.workspaceID,
                panelID: materialized.panelID
            ))
            SurfacePaneFactory.close(panelID: projection.panelID, in: projection.workspaceID)
        } catch {
            materializedPanels.remove(projection.panelID)
        }
    }

    /// Uses the generation-aware resolver when available and retains the
    /// legacy tree walk for older cmux-tui daemons.
    static func resolveSurfaceID(
        terminalID: String,
        socketPath: String,
        link: CloudMachineLink
    ) async -> UInt64? {
        if let arguments = CloudTuiCommandLine.resolveTerminalArguments(
            socketPath: socketPath,
            terminalID: terminalID
        ), let resolved = try? await link.run(arguments: arguments),
           let surfaceID = CloudTuiLegacySnapshotParser.resolvedSurfaceID(from: resolved) {
            return surfaceID
        }
        guard let tree = try? await link.run(
            arguments: CloudTuiCommandLine.legacyListWorkspacesArguments(socketPath: socketPath)
        ) else { return nil }
        return CloudTuiLegacySnapshotParser.surfaceID(from: tree, terminalID: terminalID)
    }
}

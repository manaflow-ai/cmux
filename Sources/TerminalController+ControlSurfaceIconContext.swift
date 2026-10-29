import Bonsplit
import CmuxControlSocket
import Foundation

extension TerminalController {
    /// SVG parsing and rasterization stay on the socket worker; only target/lease commits hop to UI.
    nonisolated func controlSurfaceIcon(_ inputs: ControlSurfaceIconInputs) -> ControlCallResult {
        guard !Thread.isMainThread else {
            return .err(code: "unavailable", message: "Surface icons require the socket worker", data: nil)
        }
        let evidence: SurfaceIconProcessEvidence?
        if inputs.operation == .set {
            guard let pid = inputs.expectedAgentPID,
                  let process = SurfaceIconProcessEvidence(pid: pid),
                  process.startDescription == inputs.expectedProcessStart else {
                return .err(code: "ownership_mismatch", message: "Agent process identity changed", data: nil)
            }
            evidence = process
        } else {
            evidence = nil
        }
        // Reject unknown/unsupported targets before doing any raster work.
        let admitted: Bool = controlResolveOnMain { _ in
            self.surfaceIconWorkspace(inputs, evidence: evidence) != nil
        }
        guard admitted else {
            return .err(code: "ownership_mismatch", message: "No matching local terminal owner", data: nil)
        }
        let animation: TabIconAnimation?
        do {
            animation = try inputs.asset.map { try SurfaceIconSVGRenderer().render($0) }
        } catch {
            return .err(code: "invalid_params", message: "Invalid or unsupported surface icon SVG", data: nil)
        }
        // Re-read process generation after potentially expensive rendering.
        if let evidence, SurfaceIconProcessEvidence(pid: Int(evidence.identity.pid)) != evidence {
            return .err(code: "ownership_mismatch", message: "Agent process changed during rendering", data: nil)
        }
        return controlResolveOnMain { _ in
            guard let workspace = self.surfaceIconWorkspace(inputs, evidence: evidence) else {
                return .err(code: "ownership_mismatch", message: "Terminal owner changed", data: nil)
            }
            do {
                if inputs.operation == .clear {
                    guard let token = inputs.leaseToken, inputs.expectedRevision != nil else {
                        return .err(code: "invalid_params", message: "Clearing requires lease token and revision", data: nil)
                    }
                    try workspace.surfaceIconLeases.clear(
                        panelID: inputs.surfaceID, ownerID: inputs.ownerID,
                        token: token, expectedRevision: inputs.expectedRevision
                    )
                    return .ok(.object(["cleared": .bool(true)]))
                }
                if inputs.leaseToken != nil, inputs.expectedRevision == nil {
                    return .err(code: "invalid_params", message: "Updating requires the expected revision", data: nil)
                }
                let entry = try workspace.surfaceIconLeases.set(
                    panelID: inputs.surfaceID, ownerID: inputs.ownerID,
                    token: inputs.leaseToken, expectedRevision: inputs.expectedRevision,
                    animation: animation, ttl: TimeInterval(inputs.ttlSeconds)
                )
                return .ok(.object([
                    "lease_token": .string(entry.token.uuidString),
                    "revision": .int(Int64(entry.revision)),
                    "ttl_seconds": .int(Int64(inputs.ttlSeconds)),
                ]))
            } catch SurfaceIconLeaseStore.LeaseError.ownershipConflict {
                return .err(code: "conflict", message: "Surface icon already has an owner", data: nil)
            } catch {
                return .err(code: "stale_lease", message: "Surface icon lease or revision is stale", data: nil)
            }
        }
    }

    @MainActor
    private func surfaceIconWorkspace(
        _ inputs: ControlSurfaceIconInputs, evidence: SurfaceIconProcessEvidence?
    ) -> Workspace? {
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false, windowID: nil, groupID: nil,
            workspaceID: inputs.workspaceID, surfaceID: inputs.surfaceID, paneID: nil
        )
        guard let manager = resolveTabManager(routing: routing),
              let workspace = manager.tabs.first(where: { $0.id == inputs.workspaceID }),
              !workspace.isRetiredFromOwningTabManager,
              workspace.remoteConfiguration == nil,
              let panel = workspace.panels[inputs.surfaceID] as? TerminalPanel,
              !panel.surface.isRemoteTerminal,
              workspace.cloudProjectedResource(forPanel: inputs.surfaceID) == nil,
              panel.cloudAttachment == nil,
              workspace.surfaceIdFromPanelId(inputs.surfaceID) != nil else { return nil }
        guard inputs.operation == .set else { return workspace }
        guard let evidence,
              let keys = workspace.agentPIDKeysByPanelId[inputs.surfaceID],
              keys.contains(where: {
                  workspace.agentPIDs[$0] == evidence.identity.pid
                      && workspace.agentPIDProcessIdentitiesByKey[$0] == evidence.identity
              }),
              let terminalDevice = panel.surface.controllingTTYDeviceIdentifier,
              terminalDevice == Int64(evidence.terminalDevice),
              let foreground = panel.surface.foregroundProcessID(),
              Int32(foreground) == evidence.processGroup else { return nil }
        return workspace
    }
}

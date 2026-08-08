internal import CMUXMobileCore
internal import CmuxMobileRPC
public import CmuxMobileShellModel
internal import Foundation

struct VisibleWorkspaceScrollbackPrefetch {
    let delivery: TerminalOutputDelivery
    let fetchedAt: Date
}

extension MobileShellComposite {
    private static var visibleWorkspaceScrollbackPrefetchLifetime: TimeInterval { 15 }

    /// Warms the focused terminal for each workspace row currently on screen.
    ///
    /// The replay is retained briefly and applied synchronously when a terminal
    /// surface mounts. A normal cold replay still follows, repairing any output
    /// produced between this fetch and the tap.
    public func prefetchScrollback(
        forVisibleWorkspaceIDs workspaceIDs: Set<MobileWorkspacePreview.ID>
    ) {
        guard usesScreenAnchoredRenderGrid else { return }
        let surfaceIDs: [String] = workspaceIDs.compactMap { workspaceID in
            guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else {
                return nil
            }
            return (workspace.terminals.first(where: { $0.isFocused && $0.isReady })
                ?? workspace.terminals.first(where: \.isReady))?.id.rawValue
        }
        let surfaces = Set(surfaceIDs)
        visibleWorkspaceScrollbackPrefetchSurfaceIDs = surfaces

        let departedSurfaceIDs = visibleWorkspaceScrollbackPrefetchTasksBySurfaceID.keys.filter {
            !surfaces.contains($0)
        }
        for surfaceID in departedSurfaceIDs {
            visibleWorkspaceScrollbackPrefetchTasksBySurfaceID[surfaceID]?.cancel()
            visibleWorkspaceScrollbackPrefetchTasksBySurfaceID.removeValue(forKey: surfaceID)
            visibleWorkspaceScrollbackPrefetchRequestIDsBySurfaceID.removeValue(forKey: surfaceID)
        }

        let now = runtime?.now() ?? Date()
        visibleWorkspaceScrollbackPrefetchesBySurfaceID = visibleWorkspaceScrollbackPrefetchesBySurfaceID.filter {
            now.timeIntervalSince($0.value.fetchedAt) < Self.visibleWorkspaceScrollbackPrefetchLifetime
        }

        for surfaceID in surfaces {
            guard !hasTerminalOutputSink(surfaceID: surfaceID),
                  visibleWorkspaceScrollbackPrefetchTasksBySurfaceID[surfaceID] == nil,
                  visibleWorkspaceScrollbackPrefetchesBySurfaceID[surfaceID] == nil,
                  let workspaceID = workspaceID(forTerminalID: surfaceID) else {
                continue
            }
            let target = workspaceMutationTarget(for: workspaceID)
            guard let client = target.client else { continue }
            let remoteWorkspaceID = remoteWorkspaceID(for: workspaceID)
            let requestID = UUID()
            visibleWorkspaceScrollbackPrefetchRequestIDsBySurfaceID[surfaceID] = requestID
            visibleWorkspaceScrollbackPrefetchTasksBySurfaceID[surfaceID] = Task { @MainActor [weak self] in
                defer {
                    if self?.visibleWorkspaceScrollbackPrefetchRequestIDsBySurfaceID[surfaceID]
                        == requestID {
                        self?.visibleWorkspaceScrollbackPrefetchTasksBySurfaceID.removeValue(forKey: surfaceID)
                        self?.visibleWorkspaceScrollbackPrefetchRequestIDsBySurfaceID.removeValue(forKey: surfaceID)
                    }
                }
                do {
                    let request = try MobileCoreRPCClient.requestData(
                        method: "mobile.terminal.replay",
                        params: [
                            "workspace_id": remoteWorkspaceID.rawValue,
                            "surface_id": surfaceID,
                            "anchor": MobileTerminalRenderGridFrame.Anchor.screen.rawValue,
                            "max_scrollback_rows": MobileTerminalScrollbackPreference.resolve(),
                        ]
                    )
                    let data = try await client.sendRequest(request)
                    guard
                        let self,
                        !Task.isCancelled,
                        self.visibleWorkspaceScrollbackPrefetchSurfaceIDs.contains(surfaceID),
                        !self.hasTerminalOutputSink(surfaceID: surfaceID),
                        let payload = try? MobileTerminalReplayResponse.decode(data),
                        let delivery = self.visibleWorkspaceScrollbackDelivery(
                            payload: payload,
                            surfaceID: surfaceID
                        )
                    else { return }
                    self.visibleWorkspaceScrollbackPrefetchesBySurfaceID[surfaceID] =
                        VisibleWorkspaceScrollbackPrefetch(
                            delivery: delivery,
                            fetchedAt: self.runtime?.now() ?? Date()
                        )
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }
        }
    }

    private func visibleWorkspaceScrollbackDelivery(
        payload: MobileTerminalReplayResponse,
        surfaceID: String
    ) -> TerminalOutputDelivery? {
        if let frame = payload.renderGrid, frame.surfaceID == surfaceID, frame.full {
            return TerminalOutputDelivery(
                renderGrid: frame,
                replaceable: true,
                viewportPolicy: frame.mobileViewportPolicy
            )
        }
        if let snapshot = payload.snapshotBase64.flatMap({ Data(base64Encoded: $0) }),
           !snapshot.isEmpty {
            return TerminalOutputDelivery(
                bytes: Self.terminalSnapshotReplacementBytes(snapshot),
                replaceable: true,
                viewportPolicy: .natural,
                endSequence: payload.sequence
            )
        }
        return nil
    }

    func deliverVisibleWorkspaceScrollbackPrefetchIfAvailable(surfaceID: String) {
        visibleWorkspaceScrollbackPrefetchTasksBySurfaceID[surfaceID]?.cancel()
        visibleWorkspaceScrollbackPrefetchTasksBySurfaceID.removeValue(forKey: surfaceID)
        visibleWorkspaceScrollbackPrefetchRequestIDsBySurfaceID.removeValue(forKey: surfaceID)
        guard let prefetched = visibleWorkspaceScrollbackPrefetchesBySurfaceID.removeValue(
            forKey: surfaceID
        ) else { return }
        let now = runtime?.now() ?? Date()
        guard now.timeIntervalSince(prefetched.fetchedAt)
            < Self.visibleWorkspaceScrollbackPrefetchLifetime else {
            return
        }
        deliverVisibleWorkspaceScrollbackPrefetch(prefetched.delivery, surfaceID: surfaceID)
    }
}

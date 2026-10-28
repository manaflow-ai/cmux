import Foundation

@MainActor
extension RemoteTmuxController {
    /// Every mirrored tmux pane find-window can search, ordered the way the
    /// sidebar and tab strip show them, with `focusedWorkspaceId`'s panes first.
    ///
    /// - Parameter workspaceOrder: workspace ids in sidebar order across windows.
    func findWindowCandidates(
        workspaceOrder: [UUID],
        focusedWorkspaceId: UUID?
    ) -> [RemoteTmuxFindWindowCandidate] {
        var workspaceRank: [UUID: Int] = [:]
        for (index, id) in workspaceOrder.enumerated() where workspaceRank[id] == nil {
            workspaceRank[id] = index + 1
        }
        if let focusedWorkspaceId { workspaceRank[focusedWorkspaceId] = 0 }
        var candidates: [RemoteTmuxFindWindowCandidate] = []
        for mirror in sessionMirrors.values where !mirror.connection.exited {
            guard let workspaceId = mirror.mirroredWorkspaceId else { continue }
            let source = mirror.connection
            let hostKey = Self.findWindowHostKey(mirror.host)
            let rank = workspaceRank[workspaceId] ?? workspaceOrder.count + 1
            for (windowIndex, windowId) in source.windowOrder.enumerated() {
                guard let window = source.windowsByID[windowId] else { continue }
                let panes = window.paneIDsInOrder
                for (paneIndex, paneId) in panes.enumerated() {
                    let metadata = source.paneTitleMetadataByPane[paneId]
                    candidates.append(RemoteTmuxFindWindowCandidate(
                        id: .init(hostKey: hostKey, paneId: paneId),
                        hostLabel: mirror.host.destination,
                        sessionName: mirror.sessionName,
                        windowId: windowId,
                        windowName: window.name,
                        paneId: paneId,
                        paneIndex: paneIndex,
                        windowPaneCount: panes.count,
                        paneTitle: metadata?.title ?? "",
                        intentionalPaneTitle: metadata?.intentionalTitle,
                        workspaceId: workspaceId,
                        surfaceId: mirror.windowMirrorByWindowId[windowId]?.panelsByPaneId[paneId]?.id,
                        order: rank * 1_000_000 + windowIndex * 1_000 + paneIndex
                    ))
                }
            }
        }
        return candidates.sorted { $0.order < $1.order }
    }

    /// Reads a candidate pane's full history and screen as plain text, over the
    /// stream that carries its session.
    func readFindWindowText(for candidate: RemoteTmuxFindWindowCandidate) async -> RemoteTmuxPaneText? {
        guard let mirror = sessionMirrors.values.first(where: {
            !$0.connection.exited
                && Self.findWindowHostKey($0.host) == candidate.id.hostKey
                && $0.connection.windowsByID[candidate.windowId] != nil
        }) else { return nil }
        let source = mirror.connection
        let reader = RemoteTmuxPaneTextReader(query: { command in
            await source.queryOutcome(command, timeout: 30)
        })
        return await reader.read(paneId: candidate.paneId)
    }

    /// Identifies a tmux server: pane ids are unique only within one.
    static func findWindowHostKey(_ host: RemoteTmuxHost) -> String {
        "\(host.destination):\(host.port.map(String.init) ?? "")"
    }
}

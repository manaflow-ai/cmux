import Foundation

/// Read dispatch shares the same live ownership witness on both execution lanes.
extension ControlCommandCoordinator {
    // MARK: - Summary payload

    /// Builds one workspace summary payload from a pre-minted workspace ref
    /// and caller-owned selection keys. `nonisolated`: the worker-lane
    /// list/current bodies build rows off-main; the ref is minted inside
    /// their resolution hop.
    nonisolated func workspaceSummaryPayload(
        _ summary: ControlWorkspaceSummary,
        index: Int?,
        selected: Bool,
        workspaceRef: JSONValue
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(summary.id.uuidString),
            "ref": workspaceRef,
            "title": .string(summary.title),
            "custom_title": orNull(summary.customTitle),
            "has_custom_title": .bool(!(summary.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)),
            "description": orNull(summary.customDescription),
            "selected": .bool(selected),
            "pinned": .bool(summary.isPinned),
            "listening_ports": .array(summary.listeningPorts.map { .int(Int64($0)) }),
            "remote": summary.remoteStatus,
            "current_directory": orNull(summary.currentDirectory),
            "custom_color": orNull(summary.customColor),
            "latest_conversation_message": orNull(summary.latestConversationMessage),
            "latest_submitted_message": orNull(summary.latestSubmittedMessage),
            "latest_submitted_at": orNull(summary.latestSubmittedAt),
        ]
        if let index {
            object["index"] = .int(Int64(index))
        }
        return .object(object)
    }

    // MARK: - List / current

    /// The `workspace.list` hop outcome: the Sendable resolution plus the refs
    /// the payload embeds, minted inside the hop in the payload's literal
    /// order (per-row workspace refs, then the window ref).
    private enum WorkspaceListHopOutcome: Sendable {
        case tabManagerUnavailable
        case relayWorkspace(id: UUID, title: String)
        case resolved(
            windowID: UUID?,
            workspaces: [ControlWorkspaceSummary],
            selectedIndex: Int?,
            workspaceRefs: [JSONValue],
            windowRef: JSONValue
        )
    }

    /// `workspace.list` — every workspace in the resolved window.
    ///
    /// Worker-lane resolution read (tranche D of issue #5757): routing
    /// resolution, the summary witness, and ref minting take ONE
    /// `controlResolveOnMain` hop (which refreshes known refs first, exactly
    /// like the main-lane dispatch preamble); the per-workspace JSON row build
    /// and the reply encode run on the calling socket-worker thread.
    nonisolated func workspaceList(
        _ params: [String: JSONValue],
        context: (any ControlCommandContext)?
    ) -> ControlCallResult {
        guard let context else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let outcome: WorkspaceListHopOutcome = context.controlResolveOnMain { seam in
            switch seam.controlWorkspaceList(routing: self.routingSelectors(params)) {
            case .tabManagerUnavailable:
                return .tabManagerUnavailable
            case .relayWorkspace(let id, let title):
                return .relayWorkspace(id: id, title: title)
            case .resolved(let windowID, let workspaces, let selectedIndex):
                return .resolved(
                    windowID: windowID,
                    workspaces: workspaces,
                    selectedIndex: selectedIndex,
                    workspaceRefs: workspaces.map { self.ref(.workspace, $0.id) },
                    windowRef: self.ref(.window, windowID)
                )
            }
        }
        switch outcome {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .relayWorkspace(let id, let title):
            return .ok(.object([
                "scope": .string("remote_workspace"),
                "workspaces": .array([.object(["id": .string(id.uuidString), "title": .string(title)])])
            ]))
        case let .resolved(windowID, workspaces, selectedIndex, workspaceRefs, windowRef):
            let rows: [JSONValue] = workspaces.enumerated().map { index, summary in
                workspaceSummaryPayload(
                    summary,
                    index: index,
                    selected: index == selectedIndex,
                    workspaceRef: workspaceRefs[index]
                )
            }
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": windowRef,
                "workspaces": .array(rows),
            ]))
        }
    }
}

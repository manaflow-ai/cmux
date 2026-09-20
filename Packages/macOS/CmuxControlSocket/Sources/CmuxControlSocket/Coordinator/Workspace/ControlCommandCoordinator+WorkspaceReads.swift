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
        case relayOwnerUnavailable(message: String)
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
        // `routingSelectors` resolves opaque refs through the coordinator's
        // main-actor handle registry. The nil-context path cannot perform that
        // lookup, but it must still keep relay-owned failures scoped instead
        // of leaking the generic local "TabManager" diagnostic.
        let relayOwnerMarkerPresent: Bool = {
            guard let value = params["_cmux_remote_workspace_id"] else { return false }
            if case .null = value { return false }
            return true
        }()
        guard let context else {
            return !relayOwnerMarkerPresent
                ? .err(code: "unavailable", message: "TabManager not available", data: nil)
                : .err(
                    code: "remote_relay_workspace_denied",
                    message: "",
                    data: nil
                )
        }
        let outcome: WorkspaceListHopOutcome = context.controlResolveOnMain { seam in
            let routing = self.routingSelectors(params)
            switch seam.controlWorkspaceList(routing: routing) {
            case .tabManagerUnavailable:
                return .tabManagerUnavailable
            case .relayOwnerUnavailable:
                return .relayOwnerUnavailable(message: seam.controlWorkspaceStrings().relayOwnerUnavailable)
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
        case .relayOwnerUnavailable(let message):
            return .err(
                code: "remote_relay_workspace_denied",
                message: message,
                data: nil
            )
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

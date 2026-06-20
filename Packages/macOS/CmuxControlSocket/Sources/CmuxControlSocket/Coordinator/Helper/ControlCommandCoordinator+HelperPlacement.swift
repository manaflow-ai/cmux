internal import Foundation

extension ControlCommandCoordinator {
    func helperVisibleIdentifyPayload(params: [String: JSONValue]) -> HelperVisibleIdentify {
        let payload = systemContext?.controlSystemIdentify(params: params) ?? .object([:])
        guard case .object(let object) = payload else {
            return HelperVisibleIdentify(focused: [:], caller: [:])
        }
        let focused: [String: JSONValue]
        if case .object(let focusedObject)? = object["focused"] {
            focused = focusedObject
        } else {
            focused = [:]
        }
        let caller: [String: JSONValue]
        if case .object(let callerObject)? = object["caller"] {
            caller = callerObject
        } else {
            caller = [:]
        }
        return HelperVisibleIdentify(focused: focused, caller: caller)
    }

    func helperVisiblePlacement(
        in snapshot: ControlPaneListSnapshot,
        focused: [String: JSONValue],
        health: ControlSurfaceHealthSnapshot,
        requestedType: String
    ) -> HelperVisiblePlacement {
        guard snapshot.panes.count > 1 else { return .create }
        let focusedPaneID = uuidAny(focused["pane_id"]) ?? snapshot.panes.first(where: \.isFocused)?.paneID
        let candidates = snapshot.panes.filter { pane in
            guard pane.paneID != focusedPaneID else { return false }
            return !pane.surfaceIDs.isEmpty
        }
        guard !candidates.isEmpty else { return .create }

        let orderedCandidates = helperVisibleOrderedCandidatePanes(
            candidates,
            in: snapshot,
            focusedPaneID: focusedPaneID
        )
        let healthEntriesByID = Dictionary(uniqueKeysWithValues: health.surfaces.map { entry in
            (entry.surfaceID, entry)
        })
        let visibleEntriesByID = Dictionary(uniqueKeysWithValues: health.surfaces.compactMap { entry in
            entry.visibleInUI == true ? (entry.surfaceID, entry) : nil
        })
        for pane in orderedCandidates {
            if let entry = helperVisiblePreferredVisibleSurface(
                in: pane,
                visibleEntriesByID: visibleEntriesByID,
                requestedType: requestedType
            ) {
                return .reuse(pane, entry)
            }
        }

        for pane in orderedCandidates {
            let hasRequestedOrUnknownSurface = pane.surfaceIDs.contains { surfaceID in
                guard let entry = healthEntriesByID[surfaceID] else { return true }
                return normalizedToken(entry.typeRawValue) == requestedType
            }
            if hasRequestedOrUnknownSurface {
                return .blockedInvisible(pane)
            }
        }
        return .create
    }

    func helperVisibleTargetSurfaceIsVisible(
        in snapshot: ControlPaneListSnapshot,
        focused: [String: JSONValue],
        health: ControlSurfaceHealthSnapshot
    ) -> Bool {
        guard health.windowVisible == true else { return false }
        let focusedSurfaceID = uuidAny(focused["surface_id"])
            ?? snapshot.panes.first(where: \.isFocused)?.selectedSurfaceID
        guard let focusedSurfaceID else { return false }
        return health.surfaces.first { $0.surfaceID == focusedSurfaceID }?.visibleInUI == true
    }

    private func helperVisiblePreferredVisibleSurface(
        in pane: ControlPaneSummary,
        visibleEntriesByID: [UUID: ControlSurfaceHealthEntry],
        requestedType: String
    ) -> ControlSurfaceHealthEntry? {
        if let selectedSurfaceID = pane.selectedSurfaceID,
           let entry = visibleEntriesByID[selectedSurfaceID],
           normalizedToken(entry.typeRawValue) == requestedType {
            return entry
        }
        return nil
    }

    private func helperVisibleOrderedCandidatePanes(
        _ candidates: [ControlPaneSummary],
        in snapshot: ControlPaneListSnapshot,
        focusedPaneID: UUID?
    ) -> [ControlPaneSummary] {
        if let focusedPane = focusedPaneID.flatMap({ id in snapshot.panes.first { $0.paneID == id } }),
           let focusedFrame = focusedPane.pixelFrame {
            let rightSide = candidates.filter { pane in
                guard let frame = pane.pixelFrame else { return false }
                return frame.x >= focusedFrame.x + (focusedFrame.width * 0.5)
            }.sorted { lhs, rhs in
                let lhsFrame = lhs.pixelFrame!
                let rhsFrame = rhs.pixelFrame!
                if lhsFrame.x == rhsFrame.x {
                    return lhsFrame.y < rhsFrame.y
                }
                return lhsFrame.x < rhsFrame.x
            }
            if !rightSide.isEmpty {
                return rightSide
            }
            return []
        }

        return Array(candidates.reversed())
    }

    func helperVisibleReuseResult(
        helperPane: ControlPaneSummary,
        helperSurface: ControlSurfaceHealthEntry,
        focusedWorkspaceID: UUID,
        focusedWindowID: UUID?
    ) -> ControlCallResult {
        .ok(.object([
            "window_id": orNull(focusedWindowID?.uuidString),
            "window_ref": ref(.window, focusedWindowID),
            "workspace_id": .string(focusedWorkspaceID.uuidString),
            "workspace_ref": ref(.workspace, focusedWorkspaceID),
            "pane_id": .string(helperPane.paneID.uuidString),
            "pane_ref": ref(.pane, helperPane.paneID),
            "surface_id": .string(helperSurface.surfaceID.uuidString),
            "surface_ref": ref(.surface, helperSurface.surfaceID),
            "type": .string(helperSurface.typeRawValue),
        ]))
    }

    func helperVisibleBaseCreateParams(
        from params: [String: JSONValue],
        focusedWorkspaceID: UUID,
        focusedWindowID: UUID?
    ) -> [String: JSONValue] {
        var createParams: [String: JSONValue] = [
            "workspace_id": .string(focusedWorkspaceID.uuidString),
            "focus": .bool(false),
        ]
        if let focusedWindowID {
            createParams["window_id"] = .string(focusedWindowID.uuidString)
        }
        for key in [
            "type",
            "url",
            "provider",
            "provider_id",
            "renderer",
            "renderer_kind",
            "working_directory",
            "startup_environment",
            "initial_env",
            "initial_divider_position",
        ] {
            if let value = params[key] {
                createParams[key] = value
            }
        }
        return createParams
    }
}

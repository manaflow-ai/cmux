internal import Foundation

/// The remaining surface-domain bodies (move/reorder/refresh/clear_history/
/// trigger_flash/send_text/send_key/read_text/resume.*/report_*/ports_kick and the
/// `debug.terminals` passthrough), split out of
/// `ControlCommandCoordinator+Surface.swift` to keep each file under the 500-line
/// budget. See that file's doc comment for the domain overview.
extension ControlCommandCoordinator {

    // `surface.move` lives in `ControlCommandCoordinator+SurfaceMove.swift`
    // (its own file, given the routing/branch orchestration it owns).

    // MARK: - reorder

    /// `surface.reorder` — reorder a surface within its pane.
    func surfaceReorder(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let surfaceID = uuid(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        let index = int(params, "index")
        let beforeSurfaceID = uuid(params, "before_surface_id")
        let afterSurfaceID = uuid(params, "after_surface_id")
        let targetCount = (index != nil ? 1 : 0)
            + (beforeSurfaceID != nil ? 1 : 0)
            + (afterSurfaceID != nil ? 1 : 0)
        if targetCount != 1 {
            return .err(
                code: "invalid_params",
                message: "Specify exactly one of index, before_surface_id, or after_surface_id",
                data: nil
            )
        }

        let inputs = ControlSurfaceReorderInputs(
            index: index,
            beforeSurfaceID: beforeSurfaceID,
            afterSurfaceID: afterSurfaceID
        )
        let resolution = context?.controlSurfaceReorder(
            surfaceID: surfaceID,
            inputs: inputs,
            requestedFocus: bool(params, "focus") ?? false
        ) ?? .surfaceNotFound(surfaceID)
        switch resolution {
        case .surfaceNotFound(let id):
            return .err(
                code: "not_found",
                message: "Surface not found",
                data: .object(["surface_id": .string(id.uuidString)])
            )
        case .anchorNotInSamePane:
            return .err(code: "invalid_params", message: "Anchor surface must be in the same pane", data: nil)
        case .reorderFailed:
            return .err(code: "internal_error", message: "Failed to reorder surface", data: nil)
        case .reordered(let windowID, let workspaceID, let paneID, let surfaceID):
            return .ok(.object([
                "window_id": .string(windowID.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "pane_id": .string(paneID.uuidString),
                "pane_ref": ref(.pane, paneID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
            ]))
        }
    }

    // MARK: - refresh

    /// `surface.refresh` — force-refresh every terminal surface.
    func surfaceRefresh(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let resolution = context?.controlSurfaceRefresh(routing: routing) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .refreshed(let windowID, let workspaceID, let refreshedCount):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "refreshed": .int(Int64(refreshedCount)),
            ]))
        }
    }

    // MARK: - clear_history

    /// `surface.clear_history` — clear a terminal surface's screen/history.
    func surfaceClearHistory(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let resolution = context?.controlSurfaceClearHistory(
            routing: routing,
            surfaceID: uuid(params, "surface_id"),
            hasSurfaceIDParam: params["surface_id"] != nil
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .surfaceNotFoundForID:
            return .err(code: "not_found", message: "Surface not found for the given surface_id", data: nil)
        case .noFocusedSurface:
            return .err(code: "not_found", message: "No focused surface", data: nil)
        case .surfaceNotTerminal(let id):
            return .err(
                code: "invalid_params",
                message: "Surface is not a terminal",
                data: .object(["surface_id": .string(id.uuidString)])
            )
        case .bindingActionUnavailable:
            return .err(code: "not_supported", message: "clear_screen binding action is unavailable", data: nil)
        case .cleared(let windowID, let workspaceID, let surfaceID):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
            ]))
        }
    }

    // MARK: - trigger_flash

    /// `surface.trigger_flash` — flash a surface's focus indicator.
    func surfaceTriggerFlash(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let resolution = context?.controlSurfaceTriggerFlash(
            routing: routing,
            surfaceID: uuid(params, "surface_id")
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .noFocusedSurface:
            return .err(code: "not_found", message: "No focused surface", data: nil)
        case .surfaceNotFound(let id):
            return .err(
                code: "not_found",
                message: "Surface not found",
                data: .object(["surface_id": .string(id.uuidString)])
            )
        case .flashed(let windowID, let workspaceID, let surfaceID):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
            ]))
        }
    }

    // MARK: - send_text / send_key

    /// The pre-minted refs of a successful send's payload (minted inside the
    /// hop in the payload's literal order: workspace, surface, window).
    struct SurfaceSendRefs: Sendable {
        let workspaceRef: JSONValue
        let surfaceRef: JSONValue
        let windowRef: JSONValue
    }

    /// The send hop outcome: the missing-param error (selected AFTER the
    /// TabManager guard, matching the legacy order), or the send resolution
    /// plus the success refs.
    private enum SurfaceSendHopOutcome: Sendable {
        case missingParam
        case resolution(ControlSurfaceSendResolution, refs: SurfaceSendRefs?)
    }

    /// `surface.send_text` — inject literal text into a terminal surface.
    ///
    /// Worker-lane send (tranche E of issue #5757): text extraction runs on
    /// the calling thread; routing resolution, the TabManager guard, the
    /// missing-text check (kept AFTER the guard so multi-error requests keep
    /// the legacy error precedence), the main-bound input injection +
    /// forceRefresh witness, and the success-ref minting take ONE
    /// `controlResolveOnMain` hop; reply shaping (localized error-string
    /// selection) and encode run on the worker. The reply is load-bearing
    /// (queued/input_queue_full/process_exited drive caller retry), so the
    /// hop stays synchronous. mainThreadCallable: the feed send-text path
    /// (AppDelegate.handleFeedRequestSendText) drives this verb through
    /// handleSocketLine on the main thread, where the hop collapses inline.
    nonisolated func surfaceSendText(
        _ params: [String: JSONValue],
        context: (any ControlCommandContext)?
    ) -> ControlCallResult {
        guard let context else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        // Legacy `params["text"] as? String` (no trim, no ref/UUID handling).
        let text: String?
        if case .string(let value)? = params["text"] {
            text = value
        } else {
            text = nil
        }
        let outcome: SurfaceSendHopOutcome = context.controlResolveOnMain { seam in
            let routing = self.routingSelectors(params)
            guard seam.controlSurfaceRoutingResolvesTabManager(routing: routing) else {
                return .resolution(.tabManagerUnavailable, refs: nil)
            }
            guard let text else { return .missingParam }
            let resolution = seam.controlSurfaceSendText(
                routing: routing,
                surfaceID: self.uuid(params, "surface_id"),
                hasSurfaceIDParam: params["surface_id"] != nil,
                text: text
            )
            return .resolution(resolution, refs: self.surfaceSendRefs(resolution))
        }
        switch outcome {
        case .missingParam:
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        case let .resolution(resolution, refs):
            return surfaceSendResult(resolution, refs: refs, context: context)
        }
    }

    /// `surface.send_key` — send a named key to a terminal surface.
    /// Worker-lane send; same shape as ``surfaceSendText(_:context:)`` minus
    /// the feed caller.
    nonisolated func surfaceSendKey(
        _ params: [String: JSONValue],
        context: (any ControlCommandContext)?
    ) -> ControlCallResult {
        guard let context else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let key = string(params, "key")
        let outcome: SurfaceSendHopOutcome = context.controlResolveOnMain { seam in
            let routing = self.routingSelectors(params)
            guard seam.controlSurfaceRoutingResolvesTabManager(routing: routing) else {
                return .resolution(.tabManagerUnavailable, refs: nil)
            }
            guard let key else { return .missingParam }
            let resolution = seam.controlSurfaceSendKey(
                routing: routing,
                surfaceID: self.uuid(params, "surface_id"),
                hasSurfaceIDParam: params["surface_id"] != nil,
                key: key
            )
            return .resolution(resolution, refs: self.surfaceSendRefs(resolution))
        }
        switch outcome {
        case .missingParam:
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        case let .resolution(resolution, refs):
            return surfaceSendResult(resolution, refs: refs, key: key, context: context)
        }
    }

    /// Mints the success payload's refs for a `.sent` resolution, inside the
    /// hop, in the payload's literal order (workspace, surface, window); no
    /// refs mint on error resolutions, exactly like the legacy in-payload
    /// minting.
    private func surfaceSendRefs(_ resolution: ControlSurfaceSendResolution) -> SurfaceSendRefs? {
        guard case .sent(let windowID, let workspaceID, let surfaceID, _) = resolution else {
            return nil
        }
        return SurfaceSendRefs(
            workspaceRef: ref(.workspace, workspaceID),
            surfaceRef: ref(.surface, surfaceID),
            windowRef: ref(.window, windowID)
        )
    }

    /// Shapes the shared send-text / send-key result, selecting the localized
    /// terminal-input error messages from the app-resolved strings.
    /// `nonisolated`: runs on the worker over the Sendable resolution and the
    /// hop's pre-minted success refs; the strings witness is a pure bundle
    /// lookup.
    private nonisolated func surfaceSendResult(
        _ resolution: ControlSurfaceSendResolution,
        refs: SurfaceSendRefs?,
        key: String? = nil,
        context: (any ControlCommandContext)?
    ) -> ControlCallResult {
        let strings = context?.controlSurfaceInputStrings()
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .surfaceNotFoundForID:
            return .err(code: "not_found", message: "Surface not found for the given surface_id", data: nil)
        case .noFocusedSurface:
            return .err(code: "not_found", message: "No focused surface", data: nil)
        case .surfaceNotTerminal(let id):
            return .err(
                code: "invalid_params",
                message: "Surface is not a terminal",
                data: .object(["surface_id": .string(id.uuidString)])
            )
        case .unknownKey:
            return .err(
                code: "invalid_params",
                message: "Unknown key",
                data: .object(["key": .string(key ?? "")])
            )
        case .inputQueueFull(let id):
            return .err(
                code: "input_queue_full",
                message: strings?.inputQueueFull ?? "",
                data: .object(["surface_id": .string(id.uuidString)])
            )
        case .surfaceUnavailable(let id):
            return .err(
                code: "surface_unavailable",
                message: strings?.surfaceUnavailable ?? "",
                data: .object(["surface_id": .string(id.uuidString)])
            )
        case .processExited(let id):
            return .err(
                code: "process_exited",
                message: strings?.processExited ?? "",
                data: .object(["surface_id": .string(id.uuidString)])
            )
        case .sent(let windowID, let workspaceID, let surfaceID, let queued):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": refs?.workspaceRef ?? .null,
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": refs?.surfaceRef ?? .null,
                "queued": .bool(queued),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": refs?.windowRef ?? .null,
            ]))
        }
    }

    // `surface.read_text` is intentionally absent here: it runs on the
    // socket-worker lane (issue #5757) so its full-scrollback formatting never
    // holds the main actor, and the @MainActor coordinator seam cannot host the
    // capture-on-main / format-off-main split. See `TerminalController`'s
    // `v2SurfaceReadText` worker body.

    // MARK: - debug.terminals

    /// `debug.terminals` — the global terminal-surface debug table. The payload is
    /// dozens of irreducibly app-coupled `NSWindow`/`NSView`/Ghostty-pointer
    /// fields, so the app returns it already bridged to a ``JSONValue`` (the
    /// documented single-method passthrough exception).
    func debugTerminals(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let payload = context?.controlDebugTerminals() else {
            return .err(code: "unavailable", message: "AppDelegate not available", data: nil)
        }
        return .ok(payload)
    }

    // MARK: - helpers

}

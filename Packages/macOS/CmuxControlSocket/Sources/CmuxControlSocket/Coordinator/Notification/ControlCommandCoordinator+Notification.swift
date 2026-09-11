internal import Foundation

/// The notification domain (`notification.*`), lifted byte-faithfully from the
/// former `TerminalController.v2Notification*` bodies. Each payload is built
/// directly as a ``JSONValue`` (the typed twin of the legacy `[String: Any]`
/// dictionaries); the resulting Foundation object is identical, so the encoded
/// wire bytes match. The `notification.create_for_caller` method is NOT here:
/// it has its own self-contained app-side resolver and is left in place.
extension ControlCommandCoordinator {
    /// Runs one decoded request if it belongs to the notification domain,
    /// returning the typed result; returns `nil` otherwise so the caller can
    /// fall through. The integrator calls this from the core `handle`.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not a notification method.
    func handleNotification(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "notification.create":
            return notificationCreate(request.params)
        case "notification.create_for_surface":
            return notificationCreateForSurface(request.params)
        case "notification.create_for_target":
            return notificationCreateForTarget(request.params)
        case "notification.list":
            return notificationList()
        case "notification.clear":
            return notificationClear(request.params)
        case "notification.dismiss":
            return notificationDismiss(request.params)
        case "notification.mark_read":
            return notificationMarkRead(request.params)
        case "notification.open":
            return notificationOpen(request.params)
        case "notification.jump_to_unread":
            return notificationJumpToUnread()
        default:
            return nil
        }
    }

    // MARK: - Create

    /// `notification.create` — deliver to the resolved/focused surface.
    func notificationCreate(_ params: [String: JSONValue]) -> ControlCallResult {
        let title = rawString(params, "title") ?? "Notification"
        let subtitle = rawString(params, "subtitle") ?? ""
        let body = rawString(params, "body") ?? ""
        let resolution = context?.controlNotificationCreate(
            routing: routingSelectors(params),
            explicitSurfaceID: uuid(params, "surface_id"),
            title: title,
            subtitle: subtitle,
            body: body,
            replyShapeWire: rawString(params, "reply_shape")
        ) ?? .tabManagerUnavailable

        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: notificationWorkspaceNotFoundMessage, data: nil)
        case .surfaceNotFound(let surfaceID):
            return .err(
                code: "not_found",
                message: notificationSurfaceNotFoundMessage,
                data: .object(["surface_id": .string(surfaceID.uuidString)])
            )
        case .delivered(let workspaceID, let surfaceID, let notificationID):
            let result: [String: JSONValue] = [
                "workspace_id": .string(workspaceID.uuidString),
                "surface_id": orNull(surfaceID?.uuidString),
                "id": orNull(notificationID?.uuidString),
            ]
            return .ok(.object(result))
        }
    }

    /// `notification.create_for_surface` — deliver to a required surface in the
    /// resolved workspace, echoing the workspace/surface/window identity.
    func notificationCreateForSurface(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let surfaceID = uuid(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        let title = rawString(params, "title") ?? "Notification"
        let subtitle = rawString(params, "subtitle") ?? ""
        let body = rawString(params, "body") ?? ""
        let resolution = context?.controlNotificationCreateForSurface(
            routing: routingSelectors(params),
            surfaceID: surfaceID,
            title: title,
            subtitle: subtitle,
            body: body,
            replyShapeWire: rawString(params, "reply_shape")
        ) ?? .tabManagerUnavailable
        return targetedDeliveryResult(resolution)
    }

    /// `notification.create_for_target` — deliver to a required workspace +
    /// surface, echoing the workspace/surface/window identity.
    func notificationCreateForTarget(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let workspaceID = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let surfaceID = uuid(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        let title = rawString(params, "title") ?? "Notification"
        let subtitle = rawString(params, "subtitle") ?? ""
        let body = rawString(params, "body") ?? ""
        let resolution = context?.controlNotificationCreateForTarget(
            routing: routingSelectors(params),
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            title: title,
            subtitle: subtitle,
            body: body,
            replyShapeWire: rawString(params, "reply_shape")
        ) ?? .tabManagerUnavailable
        return targetedDeliveryResult(resolution)
    }

    /// The shared result shaping for `create_for_surface` / `create_for_target`.
    private func targetedDeliveryResult(
        _ resolution: ControlNotificationTargetedDeliveryResolution
    ) -> ControlCallResult {
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound(let workspaceID):
            let data: JSONValue? = workspaceID.map { .object(["workspace_id": .string($0.uuidString)]) }
            return .err(code: "not_found", message: notificationWorkspaceNotFoundMessage, data: data)
        case .surfaceNotFound(let surfaceID):
            return .err(
                code: "not_found",
                message: notificationSurfaceNotFoundMessage,
                data: .object(["surface_id": .string(surfaceID.uuidString)])
            )
        case .delivered(let workspaceID, let surfaceID, let windowID, let notificationID):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "id": orNull(notificationID?.uuidString),
            ]))
        }
    }

    // MARK: - List / clear

    /// `notification.list` — every notification, with read state.
    func notificationList() -> ControlCallResult {
        let items = (context?.controlNotificationList() ?? []).map {
            notificationPayload($0, opened: nil, includeReadState: true)
        }
        return .ok(.object(["notifications": .array(items)]))
    }

    /// `notification.clear` — clear all notifications, or a workspace/surface
    /// scope. The no-parameter form retains the legacy global-clear payload.
    /// A `caller=true` request uses the same target resolver as
    /// `notification.create_for_caller` for ergonomic script cleanup.
    func notificationClear(_ params: [String: JSONValue]) -> ControlCallResult {
        let callerValue = bool(params, "caller")
        guard !hasNonNull(params, "caller") || callerValue != nil else {
            return .err(
                code: "invalid_params",
                message: notificationClearCallerInvalidMessage,
                data: nil
            )
        }
        let caller = callerValue ?? false
        let hasCallerOnlySelectors = [
            "preferred_workspace_id",
            "preferred_surface_id",
            "caller_tty",
            "prefer_tty",
        ].contains { hasNonNull(params, $0) }
        guard caller || !hasCallerOnlySelectors else {
            return .err(
                code: "invalid_params",
                message: notificationClearCallerSelectorsRequireCallerMessage,
                data: nil
            )
        }
        let hasWorkspaceSelector = hasNonNull(params, "workspace_id") || hasNonNull(params, "tab_id")
        let hasSurfaceSelector = hasNonNull(params, "surface_id")

        if caller {
            guard !hasWorkspaceSelector, !hasSurfaceSelector else {
                return .err(
                    code: "invalid_params",
                    message: notificationClearCallerScopeConflictMessage,
                    data: nil
                )
            }
            if hasNonNull(params, "preferred_workspace_id"),
               uuid(params, "preferred_workspace_id") == nil {
                return .err(
                    code: "invalid_params",
                    message: notificationClearPreferredWorkspaceIDInvalidMessage,
                    data: nil
                )
            }
            if hasNonNull(params, "preferred_surface_id"),
               uuid(params, "preferred_surface_id") == nil {
                return .err(
                    code: "invalid_params",
                    message: notificationClearPreferredSurfaceIDInvalidMessage,
                    data: nil
                )
            }
            let resolution = context?.controlNotificationClearForCaller(
                preferredWorkspaceID: uuid(params, "preferred_workspace_id"),
                preferredSurfaceID: uuid(params, "preferred_surface_id"),
                callerTTY: rawString(params, "caller_tty"),
                preferTTY: bool(params, "prefer_tty") ?? false
            ) ?? .tabManagerUnavailable
            return scopedClearResult(resolution)
        }

        guard !hasSurfaceSelector || hasWorkspaceSelector else {
            return .err(
                code: "invalid_params",
                message: notificationClearSurfaceIDRequiresWorkspaceMessage,
                data: nil
            )
        }

        guard !hasWorkspaceSelector, !hasSurfaceSelector else {
            let workspaceID: UUID?
            if hasNonNull(params, "workspace_id") {
                workspaceID = uuid(params, "workspace_id")
            } else {
                workspaceID = uuid(params, "tab_id")
            }
            guard let workspaceID else {
                return .err(
                    code: "invalid_params",
                    message: notificationClearWorkspaceIDInvalidMessage,
                    data: nil
                )
            }
            if hasSurfaceSelector, uuid(params, "surface_id") == nil {
                return .err(
                    code: "invalid_params",
                    message: notificationSurfaceIDInvalidMessage,
                    data: nil
                )
            }
            let resolution = context?.controlNotificationClear(
                routing: routingSelectors(params),
                workspaceID: workspaceID,
                surfaceID: uuid(params, "surface_id")
            ) ?? .tabManagerUnavailable
            return scopedClearResult(resolution)
        }

        context?.controlNotificationClear()
        return .ok(.object([:]))
    }

    /// Shapes a scoped clear resolution while keeping the legacy unscoped
    /// `notification.clear` response untouched.
    private func scopedClearResult(
        _ resolution: ControlNotificationClearResolution
    ) -> ControlCallResult {
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: notificationClearUnavailableMessage, data: nil)
        case .workspaceNotFound(let workspaceID):
            let data: JSONValue? = workspaceID.map {
                .object(["workspace_id": .string($0.uuidString)])
            }
            return .err(code: "not_found", message: notificationWorkspaceNotFoundMessage, data: data)
        case .surfaceNotFound(let surfaceID):
            return .err(
                code: "not_found",
                message: notificationSurfaceNotFoundMessage,
                data: .object(["surface_id": .string(surfaceID.uuidString)])
            )
        case .cleared(let workspaceID, let surfaceID):
            var payload: [String: JSONValue] = [
                "cleared": .bool(true),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
            ]
            if let surfaceID {
                payload["surface_id"] = .string(surfaceID.uuidString)
                payload["surface_ref"] = ref(.surface, surfaceID)
            } else {
                payload["surface_id"] = .null
                payload["surface_ref"] = .null
            }
            return .ok(.object(payload))
        }
    }

    // MARK: - Dismiss

    /// `notification.dismiss` — remove one notification by id, or every read one.
    func notificationDismiss(_ params: [String: JSONValue]) -> ControlCallResult {
        let id = uuid(params, "id")
        let allRead = bool(params, "all_read") ?? false
        let selectorCount = (id == nil ? 0 : 1) + (allRead ? 1 : 0)

        guard selectorCount == 1 else {
            return .err(
                code: "invalid_params",
                message: notificationDismissSelectorRequiredMessage,
                data: nil
            )
        }

        if allRead {
            let dismissedCount = context?.controlNotificationDismissAllRead() ?? 0
            return .ok(.object([
                "dismissed": .int(Int64(dismissedCount)),
                "all_read": .bool(true),
            ]))
        }

        guard let id else {
            return .err(
                code: "invalid_params",
                message: notificationIDRequiredMessage,
                data: nil
            )
        }

        let resolution = context?.controlNotificationDismiss(id: id) ?? .notFound
        switch resolution {
        case .notFound:
            return .err(
                code: "not_found",
                message: notificationNotFoundMessage,
                data: .object(["id": .string(id.uuidString)])
            )
        case .dismissed(let snapshot):
            var payload = notificationPayloadObject(snapshot, opened: nil, includeReadState: true)
            payload["dismissed"] = .int(1)
            return .ok(.object(payload))
        }
    }

    // MARK: - Mark read

    /// `notification.mark_read` — mark one notification, a workspace's, or all.
    func notificationMarkRead(_ params: [String: JSONValue]) -> ControlCallResult {
        let id = uuid(params, "id")
        let tabID = uuid(params, "tab_id") ?? uuid(params, "workspace_id")
        let hasSurfaceSelector = hasNonNull(params, "surface_id")
        let surfaceID = uuid(params, "surface_id")
        let all = bool(params, "all") ?? false
        let selectorCount = (id == nil ? 0 : 1) + (tabID == nil ? 0 : 1) + (all ? 1 : 0)

        guard selectorCount == 1 else {
            return .err(
                code: "invalid_params",
                message: notificationMarkReadSelectorRequiredMessage,
                data: nil
            )
        }
        if hasSurfaceSelector, surfaceID == nil {
            return .err(
                code: "invalid_params",
                message: notificationSurfaceIDInvalidMessage,
                data: nil
            )
        }
        if hasSurfaceSelector, tabID == nil {
            return .err(
                code: "invalid_params",
                message: notificationSurfaceIDRequiresWorkspaceMessage,
                data: nil
            )
        }

        let markedCount: Int
        if let id {
            let resolution = context?.controlNotificationMarkRead(id: id) ?? .notFound
            switch resolution {
            case .notFound:
                return .err(
                    code: "not_found",
                    message: notificationNotFoundMessage,
                    data: .object(["id": .string(id.uuidString)])
                )
            case .marked(let count):
                markedCount = count
            }
        } else if let tabID {
            markedCount = context?.controlNotificationMarkRead(
                workspaceID: tabID,
                surfaceID: surfaceID,
                hasSurfaceSelector: hasSurfaceSelector
            ) ?? 0
        } else {
            // `all` is the only remaining selector (selectorCount == 1).
            markedCount = context?.controlNotificationMarkReadAll() ?? 0
        }

        var result: [String: JSONValue] = ["marked_read": .int(Int64(markedCount))]
        if let id { result["id"] = .string(id.uuidString) }
        if let tabID {
            result["workspace_id"] = .string(tabID.uuidString)
            result["workspace_ref"] = ref(.workspace, tabID)
        }
        if hasSurfaceSelector {
            result["surface_id"] = orNull(surfaceID?.uuidString)
            result["surface_ref"] = ref(.surface, surfaceID)
        }
        if all { result["all"] = .bool(true) }
        return .ok(.object(result))
    }

    // MARK: - Open / jump

    /// `notification.open` — open one notification's target.
    func notificationOpen(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let id = uuid(params, "id") else {
            return .err(
                code: "invalid_params",
                message: notificationIDRequiredMessage,
                data: nil
            )
        }
        let resolution = context?.controlNotificationOpen(id: id) ?? .notificationNotFound
        switch resolution {
        case .notificationNotFound:
            return .err(
                code: "not_found",
                message: notificationNotFoundMessage,
                data: .object(["id": .string(id.uuidString)])
            )
        case .targetNotFound(let snapshot):
            return .err(
                code: "not_found",
                message: notificationTargetNotFoundMessage,
                data: notificationPayload(snapshot, opened: false, includeReadState: true)
            )
        case .opened(let snapshot):
            return .ok(notificationPayload(snapshot, opened: true, includeReadState: true))
        }
    }

    /// `notification.jump_to_unread` — open the latest unread notification.
    func notificationJumpToUnread() -> ControlCallResult {
        guard let snapshot = context?.controlNotificationJumpToUnread() else {
            return .ok(.object(["opened": .bool(false)]))
        }
        return .ok(notificationPayload(snapshot, opened: true, includeReadState: true))
    }

    // MARK: - Payload builder (typed twin of TerminalController.notificationPayload)

    /// Builds the notification payload object, byte-faithful to the legacy
    /// `notificationPayload(_:opened:includeReadState:)`.
    private func notificationPayload(
        _ snapshot: ControlNotificationSnapshot,
        opened: Bool?,
        includeReadState: Bool
    ) -> JSONValue {
        .object(notificationPayloadObject(snapshot, opened: opened, includeReadState: includeReadState))
    }

    /// The mutable dictionary form, so `dismiss` can append `dismissed` exactly
    /// as the legacy body did before wrapping in `.ok`.
    private func notificationPayloadObject(
        _ snapshot: ControlNotificationSnapshot,
        opened: Bool?,
        includeReadState: Bool
    ) -> [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "id": .string(snapshot.id.uuidString),
            "workspace_id": .string(snapshot.workspaceID.uuidString),
            "workspace_ref": ref(.workspace, snapshot.workspaceID),
            "surface_id": orNull(snapshot.surfaceID?.uuidString),
            "surface_ref": ref(.surface, snapshot.surfaceID),
            "title": .string(snapshot.title),
            "subtitle": .string(snapshot.subtitle),
            "body": .string(snapshot.body),
            "created_at": .string(snapshot.createdAtISO8601),
            "tab_title": orNull(snapshot.tabTitle),
        ]
        if includeReadState {
            payload["is_read"] = .bool(snapshot.isRead)
        }
        if let opened {
            payload["opened"] = .bool(opened)
        }
        return payload
    }

    // MARK: - Localized error messages

    /// The localized notification messages from the app conformance, or the
    /// English defaults when no context is wired (the latter only happens
    /// pre-wiring; production always has a context). Keys/default values are
    /// identical to the legacy `String(localized:)` calls.
    private var notificationStrings: ControlNotificationStrings {
        context?.notificationStrings ?? ControlNotificationStrings(
            dismissSelectorRequired: "Select exactly one of id or all_read",
            idRequired: "Missing or invalid notification id",
            notFound: "Notification not found",
            markReadSelectorRequired: "Select exactly one of id, tab_id, or all",
            surfaceIDInvalid: "Missing or invalid surface_id",
            surfaceIDRequiresWorkspace: "surface_id requires tab_id or workspace_id",
            targetNotFound: "Notification target not found",
            clearCallerInvalid: "Missing or invalid caller",
            clearCallerSelectorsRequireCaller: "caller-only selectors require caller=true",
            clearCallerScopeConflict: "caller clear cannot be combined with workspace_id, tab_id, or surface_id",
            clearPreferredWorkspaceIDInvalid: "Missing or invalid preferred_workspace_id",
            clearPreferredSurfaceIDInvalid: "Missing or invalid preferred_surface_id",
            clearSurfaceIDRequiresWorkspace: "surface_id requires workspace_id",
            clearWorkspaceIDInvalid: "Missing or invalid workspace_id",
            workspaceNotFound: "Workspace not found",
            surfaceNotFound: "Surface not found",
            clearUnavailable: "Notifications are unavailable. Try again."
        )
    }

    private var notificationDismissSelectorRequiredMessage: String {
        notificationStrings.dismissSelectorRequired
    }

    private var notificationIDRequiredMessage: String {
        notificationStrings.idRequired
    }

    private var notificationNotFoundMessage: String {
        notificationStrings.notFound
    }

    private var notificationMarkReadSelectorRequiredMessage: String {
        notificationStrings.markReadSelectorRequired
    }

    private var notificationSurfaceIDInvalidMessage: String {
        notificationStrings.surfaceIDInvalid
    }

    private var notificationSurfaceIDRequiresWorkspaceMessage: String {
        notificationStrings.surfaceIDRequiresWorkspace
    }

    private var notificationTargetNotFoundMessage: String {
        notificationStrings.targetNotFound
    }

    private var notificationClearCallerInvalidMessage: String {
        notificationStrings.clearCallerInvalid
    }

    private var notificationClearCallerSelectorsRequireCallerMessage: String {
        notificationStrings.clearCallerSelectorsRequireCaller
    }

    private var notificationClearCallerScopeConflictMessage: String {
        notificationStrings.clearCallerScopeConflict
    }

    private var notificationClearPreferredWorkspaceIDInvalidMessage: String {
        notificationStrings.clearPreferredWorkspaceIDInvalid
    }

    private var notificationClearPreferredSurfaceIDInvalidMessage: String {
        notificationStrings.clearPreferredSurfaceIDInvalid
    }

    private var notificationClearSurfaceIDRequiresWorkspaceMessage: String {
        notificationStrings.clearSurfaceIDRequiresWorkspace
    }

    private var notificationClearWorkspaceIDInvalidMessage: String {
        notificationStrings.clearWorkspaceIDInvalid
    }

    private var notificationWorkspaceNotFoundMessage: String {
        notificationStrings.workspaceNotFound
    }

    private var notificationSurfaceNotFoundMessage: String {
        notificationStrings.surfaceNotFound
    }

    private var notificationClearUnavailableMessage: String {
        notificationStrings.clearUnavailable
    }
}

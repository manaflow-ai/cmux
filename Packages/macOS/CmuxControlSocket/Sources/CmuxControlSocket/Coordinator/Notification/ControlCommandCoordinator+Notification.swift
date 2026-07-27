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
            return notificationClear()
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
        guard let presentation = notificationPresentation(params) else {
            return .err(code: "invalid_params", message: notificationInvalidPresentationMessage, data: nil)
        }
        let resolution = context?.controlNotificationCreate(
            routing: routingSelectors(params),
            explicitSurfaceID: uuid(params, "surface_id"),
            title: title,
            subtitle: subtitle,
            body: body,
            presentation: presentation
        ) ?? .tabManagerUnavailable

        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .surfaceNotFound(let surfaceID):
            return .err(
                code: "not_found",
                message: "Surface not found",
                data: .object(["surface_id": .string(surfaceID.uuidString)])
            )
        case .delivered(let workspaceID, let surfaceID):
            return .ok(.object([
                "id": .string(presentation.notificationID.uuidString),
                "workspace_id": .string(workspaceID.uuidString),
                "surface_id": orNull(surfaceID?.uuidString),
            ]))
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
        guard let presentation = notificationPresentation(params) else {
            return .err(code: "invalid_params", message: notificationInvalidPresentationMessage, data: nil)
        }
        let resolution = context?.controlNotificationCreateForSurface(
            routing: routingSelectors(params),
            surfaceID: surfaceID,
            title: title,
            subtitle: subtitle,
            body: body,
            presentation: presentation
        ) ?? .tabManagerUnavailable
        return targetedDeliveryResult(resolution, notificationID: presentation.notificationID)
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
        guard let presentation = notificationPresentation(params) else {
            return .err(code: "invalid_params", message: notificationInvalidPresentationMessage, data: nil)
        }
        let resolution = context?.controlNotificationCreateForTarget(
            routing: routingSelectors(params),
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            title: title,
            subtitle: subtitle,
            body: body,
            presentation: presentation
        ) ?? .tabManagerUnavailable
        return targetedDeliveryResult(resolution, notificationID: presentation.notificationID)
    }

    /// The shared result shaping for `create_for_surface` / `create_for_target`.
    private func targetedDeliveryResult(
        _ resolution: ControlNotificationTargetedDeliveryResolution,
        notificationID: UUID
    ) -> ControlCallResult {
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound(let workspaceID):
            let data: JSONValue? = workspaceID.map { .object(["workspace_id": .string($0.uuidString)]) }
            return .err(code: "not_found", message: "Workspace not found", data: data)
        case .surfaceNotFound(let surfaceID):
            return .err(
                code: "not_found",
                message: "Surface not found",
                data: .object(["surface_id": .string(surfaceID.uuidString)])
            )
        case .delivered(let workspaceID, let surfaceID, let windowID):
            return .ok(.object([
                "id": .string(notificationID.uuidString),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
            ]))
        }
    }

    private func notificationPresentation(
        _ params: [String: JSONValue]
    ) -> ControlNotificationPresentation? {
        let notificationID: UUID
        if let notificationIDValue = params["notification_id"] {
            guard case .string(let rawNotificationID) = notificationIDValue,
                  let parsed = UUID(uuidString: rawNotificationID) else { return nil }
            notificationID = parsed
        } else {
            notificationID = UUID()
        }

        let rawDelivery: String
        if let deliveryValue = params["delivery"] {
            guard case .string(let value) = deliveryValue else { return nil }
            rawDelivery = value
        } else {
            rawDelivery = "settings"
        }
        let delivery: ControlNotificationPresentation.Delivery
        switch rawDelivery {
        case "settings", "default":
            delivery = .settings
        case "system":
            delivery = .system
        case "dynamicNotch", "notch":
            delivery = .dynamicNotch
        default:
            return nil
        }

        if let iconValue = params["icon"], case .string = iconValue {
            // Parsed below.
        } else if params["icon"] != nil {
            return nil
        }
        let icon = optionalTrimmedRawString(params, "icon")
        if let icon, icon.count > 128 { return nil }

        var actions: [ControlNotificationPresentation.Action] = []
        if let actionValue = params["actions"] {
            guard case .array(let rawActions) = actionValue, rawActions.count <= 4 else { return nil }
            var actionIDs: Set<String> = []
            let reservedIDs: Set<String> = ["open", "dismiss", "timeout", "replaced", "dismissed"]
            for rawAction in rawActions {
                guard case .object(let object) = rawAction,
                      Set(object.keys).isSubset(of: ["id", "title"]),
                      case .string(let rawID)? = object["id"],
                      case .string(let rawTitle)? = object["title"] else { return nil }
                let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty,
                      id.count <= 64,
                      !title.isEmpty,
                      title.count <= 80,
                      !reservedIDs.contains(id),
                      notificationControlIdentifierIsValid(id),
                      actionIDs.insert(id).inserted else { return nil }
                actions.append(.init(id: id, title: title))
            }
        }

        var inputs: [ControlNotificationPresentation.Input] = []
        if let inputValue = params["inputs"] {
            guard case .array(let rawInputs) = inputValue, rawInputs.count <= 4 else { return nil }
            var inputIDs: Set<String> = []
            for rawInput in rawInputs {
                guard case .object(let object) = rawInput,
                      Set(object.keys).isSubset(of: [
                          "id", "label", "placeholder", "initial_value", "secure",
                      ]),
                      case .string(let rawID)? = object["id"],
                      case .string(let rawLabel)? = object["label"] else { return nil }
                let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                let placeholder: String
                switch object["placeholder"] {
                case .string(let value)?:
                    placeholder = value
                case nil:
                    placeholder = ""
                default:
                    return nil
                }
                let initialValue: String
                switch object["initial_value"] {
                case .string(let value)?:
                    initialValue = value
                case nil:
                    initialValue = ""
                default:
                    return nil
                }
                let kind: ControlNotificationPresentation.Input.Kind
                switch object["secure"] {
                case .bool(true)?:
                    kind = .secure
                case .bool(false)?, nil:
                    kind = .text
                default:
                    return nil
                }
                guard !id.isEmpty,
                      id.count <= 64,
                      notificationControlIdentifierIsValid(id),
                      inputIDs.insert(id).inserted,
                      !label.isEmpty,
                      label.count <= 80,
                      placeholder.count <= 160,
                      initialValue.count <= 4_096 else { return nil }
                inputs.append(.init(
                    id: id,
                    label: label,
                    placeholder: placeholder,
                    initialValue: initialValue,
                    kind: kind
                ))
            }
        }

        let responseToken: UUID?
        if let responseTokenValue = params["response_token"] {
            guard case .string(let rawResponseToken) = responseTokenValue,
                  let parsed = UUID(uuidString: rawResponseToken) else { return nil }
            responseToken = parsed
        } else {
            responseToken = nil
        }

        let timeout: Double
        switch params["timeout"] {
        case .double(let value)?:
            timeout = value
        case .int(let value)?:
            timeout = Double(value)
        case nil:
            timeout = 8
        default:
            return nil
        }
        guard timeout.isFinite, (0...86_400).contains(timeout) else { return nil }
        guard (actions.isEmpty && inputs.isEmpty && responseToken == nil) || delivery == .dynamicNotch else { return nil }

        return ControlNotificationPresentation(
            notificationID: notificationID,
            delivery: delivery,
            iconSymbolName: icon,
            actions: actions,
            inputs: inputs,
            responseToken: responseToken,
            timeout: timeout
        )
    }

    private func notificationControlIdentifierIsValid(_ identifier: String) -> Bool {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
        )
        return identifier.unicodeScalars.allSatisfy(allowed.contains)
    }

    // MARK: - List / clear

    /// `notification.list` — every notification, with read state.
    func notificationList() -> ControlCallResult {
        let items = (context?.controlNotificationList() ?? []).map {
            notificationPayload($0, opened: nil, includeReadState: true)
        }
        return .ok(.object(["notifications": .array(items)]))
    }

    /// `notification.clear` — enqueue clearing all notifications.
    func notificationClear() -> ControlCallResult {
        context?.controlNotificationClear()
        return .ok(.object([:]))
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
            invalidPresentation: "Invalid notification presentation",
            dismissSelectorRequired: "Select exactly one of id or all_read",
            idRequired: "Missing or invalid notification id",
            notFound: "Notification not found",
            markReadSelectorRequired: "Select exactly one of id, tab_id, or all",
            surfaceIDInvalid: "Missing or invalid surface_id",
            surfaceIDRequiresWorkspace: "surface_id requires tab_id or workspace_id",
            targetNotFound: "Notification target not found"
        )
    }

    private var notificationInvalidPresentationMessage: String {
        notificationStrings.invalidPresentation
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
}

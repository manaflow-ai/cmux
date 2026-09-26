internal import Foundation

/// The workspace domain (the non-group `workspace.*` methods), lifted
/// byte-faithfully from the former `TerminalController.v2Workspace*` bodies.
/// Each payload is built directly as a ``JSONValue`` (the typed twin of the
/// legacy `[String: Any]` dictionaries); the resulting Foundation object is
/// identical, so the encoded wire bytes match.
///
/// The `workspace.group.*` methods live in `+WorkspaceGroup.swift`;
/// `workspace.action` / `extension.sidebar.snapshot` and the worker-lane
/// `workspace.remote.pty_*` (sessions/close/detach/bridge/resize) methods stay
/// on the app-side dispatcher.
extension ControlCommandCoordinator {
    /// Dispatches the non-group workspace methods this coordinator owns; returns
    /// `nil` for anything else so the core `handle(_:)` can fall through.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not an owned workspace method.
    func handleWorkspace(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "workspace.list":
            // Worker-lane resolution read (tranche D): the nonisolated body is
            // shared with the socket dispatcher's worker lane; from this
            // main-actor dispatch its hop collapses inline.
            return workspaceList(request.params, context: context)
        case "workspace.create":
            return workspaceCreate(request.params)
        case "workspace.select":
            return workspaceSelect(request.params)
        case "workspace.current":
            return workspaceCurrent(request.params, context: context)
        case "workspace.close":
            return workspaceClose(request.params)
        case "workspace.move_to_window":
            return workspaceMoveToWindow(request.params)
        case "workspace.reorder":
            return workspaceReorder(request.params)
        case "workspace.reorder_many":
            return workspaceReorderMany(request.params)
        case "workspace.prompt_submit":
            return workspacePromptSubmit(request.params)
        case "workspace.rename":
            return workspaceRename(request.params)
        case "workspace.next":
            return workspaceNext(request.params)
        case "workspace.previous":
            return workspacePrevious(request.params)
        case "workspace.last":
            return workspaceLast(request.params)
        case "workspace.last_forward":
            return workspaceLastForward(request.params)
        case "workspace.equalize_splits":
            return workspaceEqualizeSplits(request.params)
        case "workspace.remote.configure":
            return workspaceRemoteConfigure(request.params)
        case "workspace.remote.foreground_auth_ready":
            return workspaceRemoteForegroundAuthReady(request.params)
        case "workspace.remote.reconnect":
            return workspaceRemoteReconnect(request.params)
        case "workspace.remote.disconnect":
            return workspaceRemoteDisconnect(request.params)
        case "workspace.remote.status":
            return workspaceRemoteStatus(request.params)
        case "workspace.remote.pty_attach_end":
            return workspaceRemotePTYAttachEnd(request.params)
        case "workspace.remote.terminal_session_end":
            return workspaceRemoteTerminalSessionEnd(request.params)
        default:
            return nil
        }
    }

    /// The `workspace.current` hop outcome (refs minted in payload order:
    /// window, workspace).
    private enum WorkspaceCurrentHopOutcome: Sendable {
        case tabManagerUnavailable
        case noWorkspaceSelected
        case relayWorkspace(id: UUID, title: String)
        case relayOwnerUnavailable(message: String)
        case resolved(
            windowID: UUID?,
            workspaceID: UUID,
            index: Int?,
            summary: ControlWorkspaceSummary?,
            windowRef: JSONValue,
            workspaceRef: JSONValue
        )
    }

    /// `workspace.current` — the selected workspace in the resolved window.
    /// Worker-lane resolution read; see ``workspaceList(_:context:)``.
    nonisolated func workspaceCurrent(
        _ params: [String: JSONValue],
        context: (any ControlCommandContext)?
    ) -> ControlCallResult {
        let relayOwnerMarkerPresent: Bool = {
            guard let value = params["_cmux_remote_workspace_id"] else { return false }
            if case .null = value { return false }
            return true
        }()
        guard let context else {
            return relayOwnerMarkerPresent
                ? .err(code: "remote_relay_workspace_denied", message: String(localized: "socket.workspace.list.relayOwnerUnavailable", defaultValue: "Relay owner workspace is not active", bundle: .main), data: nil)
                : .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let outcome: WorkspaceCurrentHopOutcome = context.controlResolveOnMain { seam in
            switch seam.controlWorkspaceCurrent(routing: self.routingSelectors(params)) {
            case .tabManagerUnavailable:
                return .tabManagerUnavailable
            case .noWorkspaceSelected:
                return .noWorkspaceSelected
            case .relayWorkspace(let id, let title):
                return .relayWorkspace(id: id, title: title)
            case .relayOwnerUnavailable:
                return .relayOwnerUnavailable(message: seam.controlWorkspaceStrings().relayOwnerUnavailable)
            case .resolved(let windowID, let workspaceID, let index, let summary):
                return .resolved(
                    windowID: windowID,
                    workspaceID: workspaceID,
                    index: index,
                    summary: summary,
                    windowRef: self.ref(.window, windowID),
                    workspaceRef: self.ref(.workspace, workspaceID)
                )
            }
        }
        switch outcome {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .noWorkspaceSelected:
            return .err(code: "not_found", message: "No workspace selected", data: nil)
        case .relayWorkspace(let id, let title):
            return .ok(.object([
                "window_id": .null,
                "window_ref": .null,
                "workspace_id": .string(id.uuidString),
                "workspace_ref": .string(id.uuidString),
                "workspace": .object([
                    "id": .string(id.uuidString),
                    "title": .string(title),
                ]),
            ]))
        case .relayOwnerUnavailable(let message):
            return .err(code: "remote_relay_workspace_denied", message: message, data: nil)
        case let .resolved(windowID, workspaceID, index, summary, windowRef, workspaceRef):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": windowRef,
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": workspaceRef,
                // The summary row's `ref` is the same workspace id, so the
                // pre-minted ref is reused (the legacy in-payload mint was an
                // idempotent second lookup).
                "workspace": summary.map {
                    workspaceSummaryPayload($0, index: index, selected: true, workspaceRef: workspaceRef)
                } ?? .null,
            ]))
        }
    }

    // MARK: - Create

    /// `workspace.create` — create a workspace.
    ///
    /// A passthrough to the still-shared `v2WorkspaceCreate(params:tabManager:)`
    /// (which the mobile data-plane `v2MobileWorkspaceCreate` also drives), rather
    /// than a typed lift: the create body parses all ~10 params and mints refs
    /// itself, so a single source of truth is both deduplicated and exactly
    /// faithful. The conformance bridges the body's Foundation payload to a
    /// `ControlCallResult`, like `surface.move` / `debug.terminals`.
    func workspaceCreate(_ params: [String: JSONValue]) -> ControlCallResult {
        context?.controlWorkspaceCreate(params: params)
            ?? .err(code: "unavailable", message: "TabManager not available", data: nil)
    }

    // MARK: - Select / close / move

    /// `workspace.select` — select a workspace by id.
    func workspaceSelect(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        // Legacy resolved the TabManager BEFORE param validation, so unresolvable
        // routing wins over a missing/invalid param (`unavailable` first).
        guard context?.controlWorkspaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let workspaceID = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let resolution = context?.controlSelectWorkspace(
            routing: routing,
            workspaceID: workspaceID
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .notFound:
            return .err(code: "not_found", message: "Workspace not found", data: .object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
            ]))
        case .resolved(let windowID):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
            ]))
        }
    }

    /// `workspace.move_to_window` — move a workspace to another window.
    func workspaceMoveToWindow(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let workspaceID = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let windowID = uuid(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        let focusRequested = bool(params, "focus") ?? false
        guard let resolution = context?.controlMoveWorkspaceToWindow(
            workspaceID: workspaceID,
            windowID: windowID,
            focusRequested: focusRequested
        ) else {
            return .err(code: "internal_error", message: "Failed to move workspace", data: nil)
        }
        switch resolution {
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: .object([
                "workspace_id": .string(workspaceID.uuidString),
            ]))
        case .windowNotFound:
            return .err(code: "not_found", message: "Window not found", data: .object([
                "window_id": .string(windowID.uuidString),
            ]))
        case .resolved:
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "window_id": .string(windowID.uuidString),
                "window_ref": ref(.window, windowID),
            ]))
        }
    }

    // MARK: - Reorder

    /// Builds one reorder plan item's payload (the legacy
    /// `v2WorkspaceReorderPlanPayload`).
    private func workspaceReorderPlanPayload(
        _ plan: ControlWorkspaceReorderPlanItem,
        windowID: UUID?
    ) -> JSONValue {
        .object([
            "workspace_id": .string(plan.workspaceID.uuidString),
            "workspace_ref": ref(.workspace, plan.workspaceID),
            "window_id": orNull(windowID?.uuidString),
            "window_ref": ref(.window, windowID),
            "from_index": .int(Int64(plan.fromIndex)),
            "to_index": .int(Int64(plan.toIndex)),
        ])
    }

    /// The id params `workspace.reorder` resolves, in the order a caller should
    /// hear about a failure: the subject before the relative target.
    private func workspaceReorderIDKeys() -> [String] {
        ["workspace_id", "before_workspace_id", "after_workspace_id"]
    }

    /// Whether a value could ever name a workspace: a UUID, or a minted
    /// `kind:N` handle ref. `uuid(_:_:)` accepts exactly these two spellings,
    /// so anything else is a value the registry was never going to resolve —
    /// a typo, not an object that went away. Both `workspace.reorder` and
    /// `workspace.reorder_many` split on this, so the two methods agree on the
    /// same input.
    private func isWorkspaceReferenceShaped(_ raw: String) -> Bool {
        if UUID(uuidString: raw) != nil { return true }
        guard let colon = raw.firstIndex(of: ":") else { return false }
        let kind = String(raw[raw.startIndex..<colon])
        let ordinal = raw[raw.index(after: colon)...]
        // Refs are minted from `ControlHandleKind` raw values, lowercase, and
        // looked up exactly; only the `tab:` alias is lowercased first. Any
        // other prefix could never have resolved.
        let knownKind = ControlHandleKind(rawValue: kind) != nil || kind.lowercased() == "tab"
        return knownKind
            && !ordinal.isEmpty
            && ordinal.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The live workspace ids, or `nil` when the topology cannot be listed (a
    /// relay session, or a window that went away between calls).
    private func workspaceReorderLiveIDs(_ params: [String: JSONValue]) -> Set<UUID>? {
        guard case .resolved(_, let workspaces, _)? = context?.controlWorkspaceList(
            routing: routingSelectors(params)
        ) else { return nil }
        return Set(workspaces.map(\.id))
    }

    /// Builds one failure reply for a reorder, naming the id that could not be
    /// resolved instead of always naming the subject workspace.
    ///
    /// `workspace` carries the caller's own spelling, so a stale `kind:N` ref
    /// comes back verbatim and the caller can see which value to replace;
    /// `workspace_id` stays a UUID, or JSON `null` when the value never
    /// resolved to one. The planner reports one opaque `notFound` for "subject
    /// missing" and "target missing" alike, so the workspace list is re-read —
    /// on this error path only — to tell them apart.
    private func workspaceReorderResolutionFailure(
        _ params: [String: JSONValue],
        subject: String
    ) -> ControlCallResult {
        let strings = context?.controlWorkspaceStrings()
        func failure(param: String, value: String, id: UUID?) -> ControlCallResult {
            .err(code: "not_found", message: strings?.workspaceNotFound ?? "", data: .object([
                "param": .string(param),
                "workspace": .string(value),
                "workspace_id": orNull(id?.uuidString),
            ]))
        }
        let supplied = workspaceReorderIDKeys().compactMap { key -> (key: String, raw: String)? in
            guard let raw = string(params, key) else { return nil }
            return (key, raw)
        }
        if let unresolvable = supplied.first(where: { uuid(params, $0.key) == nil }) {
            // A stale `workspace:7` named a real workspace once, so it reports
            // the object as gone. `"potato"` never could, so it stays a param
            // error — the same split `workspace.reorder_many` makes.
            guard isWorkspaceReferenceShaped(unresolvable.raw) else {
                return .err(
                    code: "invalid_params",
                    message: strings?.invalidWorkspaceRef ?? "",
                    data: .object([
                        "param": .string(unresolvable.key),
                        "workspace": .string(unresolvable.raw),
                    ])
                )
            }
            return failure(param: unresolvable.key, value: unresolvable.raw, id: nil)
        }
        // With no relative target, `supplied` holds only the subject, so the
        // list read cannot distinguish anything: the branch below and the
        // fallback return byte-identical payloads. Skip it. That is the only
        // shape the sidebar sends (`SwiftViewInterpreter` defaults `Reorderable`
        // to workspace_id + index), and `controlWorkspaceList` bridges a remote
        // status payload and formats timestamps for every workspace on the main
        // actor, so this is the difference between one wasted full list read per
        // failed drop and none.
        let hasRelativeTarget = hasNonNull(params, "before_workspace_id")
            || hasNonNull(params, "after_workspace_id")
        if hasRelativeTarget,
           let live = workspaceReorderLiveIDs(params),
           let absent = supplied.first(where: { entry in
               guard let id = uuid(params, entry.key) else { return false }
               return !live.contains(id)
           }) {
            return failure(param: absent.key, value: absent.raw, id: uuid(params, absent.key))
        }
        return failure(param: "workspace_id", value: subject, id: uuid(params, "workspace_id"))
    }

    /// `workspace.reorder` — move one workspace to an index/relative target.
    func workspaceReorder(_ params: [String: JSONValue]) -> ControlCallResult {
        let strings = context?.controlWorkspaceStrings()
        guard context?.controlWorkspaceRoutingResolvesTabManager(routing: routingSelectors(params)) ?? false else {
            return .err(code: "unavailable", message: strings?.tabManagerUnavailable ?? "", data: nil)
        }
        guard let subject = string(params, "workspace_id") else {
            return .err(code: "invalid_params", message: strings?.reorderMissingWorkspaceID ?? "", data: nil)
        }
        // A ref the registry once minted names an object that is gone, which is
        // the same failure a stale `before_workspace_id` reports. A value that
        // could never have named a workspace stays `invalid_params`, and so
        // does a param `string(_:_:)` cannot read at all.
        guard let workspaceID = uuid(params, "workspace_id") else {
            return workspaceReorderResolutionFailure(params, subject: subject)
        }

        let index = int(params, "index")
        let beforeID = uuid(params, "before_workspace_id")
        let afterID = uuid(params, "after_workspace_id")
        let dryRun = bool(params, "dry_run") ?? false

        // Count supplied selectors, not resolved identities. An unknown ref
        // must neither look like a missing target nor hide a conflicting one.
        let targetCount = ["index", "before_workspace_id", "after_workspace_id"]
            .filter { hasNonNull(params, $0) }.count
        if targetCount != 1 {
            return .err(
                code: "invalid_params",
                message: strings?.reorderTargetRequired ?? "",
                data: nil
            )
        }
        if hasNonNull(params, "index"), index == nil {
            return .err(
                code: "invalid_params",
                message: strings?.reorderIndexNotAnInteger ?? "",
                data: .object(["param": .string("index")])
            )
        }
        // `hasNonNull` is true for values `uuid` can never read — `""`,
        // whitespace, and non-string JSON. There is no id to look up, so this
        // is a type error rather than a missing workspace.
        if let malformed = ["before_workspace_id", "after_workspace_id"].first(where: {
            hasNonNull(params, $0) && string(params, $0) == nil
        }) {
            // The message stays flat and shared with `workspace.reorder_many`;
            // `data.param` already names the param, so interpolating it would
            // only make the string untranslatable.
            return .err(
                code: "invalid_params",
                message: strings?.invalidWorkspaceRef ?? "",
                data: .object(["param": .string(malformed)])
            )
        }

        let resolution: ControlWorkspaceReorderResolution
        if (hasNonNull(params, "before_workspace_id") && beforeID == nil)
            || (hasNonNull(params, "after_workspace_id") && afterID == nil) {
            resolution = .notFound
        } else {
            resolution = context?.controlReorderWorkspace(
                routing: routingSelectors(params),
                workspaceID: workspaceID,
                toIndex: index,
                beforeWorkspaceID: beforeID,
                afterWorkspaceID: afterID,
                dryRun: dryRun
            ) ?? .notFound
        }
        switch resolution {
        case .notFound:
            return workspaceReorderResolutionFailure(params, subject: subject)
        case .resolved(let windowID, let plan):
            var object: [String: JSONValue] = [
                "workspace_id": .string(plan.workspaceID.uuidString),
                "workspace_ref": ref(.workspace, plan.workspaceID),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "from_index": .int(Int64(plan.fromIndex)),
                "to_index": .int(Int64(plan.toIndex)),
            ]
            object["dry_run"] = .bool(dryRun)
            object["index"] = .int(Int64(plan.toIndex))
            object["plan"] = .array([workspaceReorderPlanPayload(plan, windowID: windowID)])
            object["events"] = (!dryRun && plan.fromIndex != plan.toIndex)
                ? .array([workspaceReorderPlanPayload(plan, windowID: windowID)])
                : .array([])
            return .ok(.object(object))
        }
    }

    /// `workspace.reorder_many` — apply a desired workspace order.
    func workspaceReorderMany(_ params: [String: JSONValue]) -> ControlCallResult {
        let strings = context?.controlWorkspaceStrings()

        let rawOrder = workspaceReorderManyOrder(params)
        if let invalid = rawOrder.invalidValue {
            return .err(
                code: "invalid_params",
                message: strings?.invalidWorkspaceRef ?? "",
                data: .object(["workspace": .string(invalid)])
            )
        }
        let order = rawOrder.order
        guard !order.isEmpty else {
            return .err(
                code: "invalid_params",
                message: strings?.reorderManyMissingOrder ?? "",
                data: nil
            )
        }

        var workspaceIDs: [UUID] = []
        workspaceIDs.reserveCapacity(order.count)
        for raw in order {
            guard let workspaceID = uuidAny(.string(raw)) else {
                // The registry forgets a ref when its workspace closes, so a
                // stale `workspace:7` lands here too. It named something once:
                // report it gone, as `workspace.reorder` does for the same ref.
                // The id keys stay present, as `null`, so this reply has the
                // same shape as the `.workspaceNotFound` one below.
                if isWorkspaceReferenceShaped(raw) {
                    return .err(
                        code: "not_found",
                        message: strings?.workspaceNotFound ?? "",
                        data: .object([
                            "workspace": .string(raw),
                            "workspace_id": .null,
                            "workspace_ref": .null,
                        ])
                    )
                }
                return .err(
                    code: "invalid_params",
                    message: strings?.invalidWorkspaceRef ?? "",
                    data: .object(["workspace": .string(raw)])
                )
            }
            workspaceIDs.append(workspaceID)
        }

        let dryRun = bool(params, "dry_run") ?? false
        let resolution = context?.controlReorderWorkspacesMany(
            routing: routingSelectors(params),
            workspaceIDs: workspaceIDs,
            dryRun: dryRun
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(
                code: "unavailable",
                message: strings?.reorderManyTabManagerUnavailable ?? "",
                data: nil
            )
        case .duplicateWorkspace(let workspaceID):
            return .err(
                code: "invalid_params",
                message: strings?.reorderManyDuplicateWorkspace ?? "",
                data: .object([
                    "workspace_id": .string(workspaceID.uuidString),
                    "workspace_ref": ref(.workspace, workspaceID),
                ])
            )
        case .workspaceNotFound(let workspaceID):
            return .err(
                code: "not_found",
                message: strings?.workspaceNotFound ?? "",
                data: .object([
                    "workspace_id": .string(workspaceID.uuidString),
                    "workspace_ref": ref(.workspace, workspaceID),
                ])
            )
        case .resolved(let windowID, let plans):
            let planPayloads = plans.map { workspaceReorderPlanPayload($0, windowID: windowID) }
            let events: [JSONValue] = dryRun
                ? []
                : zip(plans, planPayloads).compactMap { plan, payload in
                    plan.fromIndex != plan.toIndex ? payload : nil
                }
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "dry_run": .bool(dryRun),
                "plan": .array(planPayloads),
                "events": .array(events),
            ]))
        }
    }

    /// Parses the `workspace_ids` / `order` params for `workspace.reorder_many`
    /// (the legacy `v2WorkspaceReorderManyOrder`), returning the trimmed order
    /// or the JSON-encoded invalid value description.
    private func workspaceReorderManyOrder(
        _ params: [String: JSONValue]
    ) -> (order: [String], invalidValue: String?) {
        if let raw = params["workspace_ids"], !isNull(raw) {
            switch raw {
            case .array(let values):
                var strings: [String] = []
                strings.reserveCapacity(values.count)
                for item in values {
                    guard case .string(let value) = item else {
                        return ([], invalidValueDescription(
                            item,
                            fallback: "<invalid_workspace_id>"
                        ))
                    }
                    strings.append(value)
                }
                return normalizeReorderManyOrder(strings)
            case .string(let value):
                return normalizeReorderManyOrder([value])
            default:
                return ([], invalidValueDescription(
                    raw,
                    fallback: "<invalid_workspace_ids>"
                ))
            }
        }

        guard let order = params["order"], !isNull(order) else { return ([], nil) }
        guard case .string(let orderString) = order else {
            return ([], invalidValueDescription(
                order,
                fallback: "<invalid_order_value>"
            ))
        }
        let refs = orderString
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return normalizeReorderManyOrder(refs)
    }

    /// The legacy `v2NormalizeWorkspaceReorderManyOrder`: trimmed entries, with
    /// the first empty entry reported as the invalid value (its raw form).
    private func normalizeReorderManyOrder(
        _ rawItems: [String]
    ) -> (order: [String], invalidValue: String?) {
        var order: [String] = []
        order.reserveCapacity(rawItems.count)
        for raw in rawItems {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return ([], raw)
            }
            order.append(trimmed)
        }
        return (order, nil)
    }

    /// The legacy `v2WorkspaceReorderManyInvalidValueDescription`: the JSON
    /// encoding of `{"value": <raw>}`, or the fallback when it can't encode.
    private func invalidValueDescription(_ value: JSONValue, fallback: String) -> String {
        let wrapped: [String: Any] = ["value": value.foundationObject]
        guard JSONSerialization.isValidJSONObject(wrapped),
              let data = try? JSONSerialization.data(withJSONObject: wrapped, options: []),
              let encoded = String(data: data, encoding: .utf8) else {
            return fallback
        }
        return encoded
    }

    // MARK: - Prompt submit / rename

    /// `workspace.prompt_submit` — submit a prompt into a workspace.
    func workspacePromptSubmit(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let workspaceID = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }

        let messageKeys = ["message", "prompt", "text", "body"]
        for key in messageKeys {
            guard let raw = params[key], !isNull(raw) else { continue }
            guard case .string = raw else {
                return .err(code: "invalid_params", message: "\(key) must be a string", data: nil)
            }
        }
        let message = messageKeys.lazy.compactMap { self.rawString(params, $0) }.first

        let resolution = context?.controlSubmitWorkspacePrompt(
            routing: routingSelectors(params),
            workspaceID: workspaceID,
            message: message
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .notFound:
            return .err(code: "not_found", message: "Workspace not found", data: .object([
                "workspace_id": .string(workspaceID.uuidString),
            ]))
        case .resolved(let windowID, let iMessageModeEnabled, let messageRecorded, let reordered, let index, let preview):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "i_message_mode_enabled": .bool(iMessageModeEnabled),
                "message_recorded": .bool(messageRecorded),
                "message_preview": orNull(preview),
                "reordered": .bool(reordered),
                "index": .int(Int64(index)),
            ]))
        }
    }

    /// `workspace.rename` — set a workspace's custom title.
    func workspaceRename(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        // Legacy resolved the TabManager BEFORE param validation, so unresolvable
        // routing wins over a missing/invalid param (`unavailable` first).
        guard context?.controlWorkspaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let workspaceID = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let title = string(params, "title") else {
            return .err(code: "invalid_params", message: "Missing or invalid title", data: nil)
        }
        let resolution = context?.controlRenameWorkspace(
            routing: routing,
            workspaceID: workspaceID,
            title: title
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .notFound:
            return .err(code: "not_found", message: "Workspace not found", data: .object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
            ]))
        case .resolved(let windowID):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "title": .string(title),
            ]))
        }
    }

    // MARK: - Navigation

    /// Shapes the shared navigation result for next/previous/last.
    private func workspaceNavigationResult(
        _ resolution: ControlWorkspaceNavigationResolution?,
        notFoundMessage: String
    ) -> ControlCallResult {
        switch resolution ?? .tabManagerUnavailable {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .notFound:
            return .err(code: "not_found", message: notFoundMessage, data: nil)
        case .resolved(let workspaceID, let windowID):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
            ]))
        }
    }

    /// `workspace.next` — select the next workspace.
    func workspaceNext(_ params: [String: JSONValue]) -> ControlCallResult {
        workspaceNavigationResult(
            context?.controlSelectNextWorkspace(routing: routingSelectors(params)),
            notFoundMessage: "No workspace selected"
        )
    }

    /// `workspace.previous` — select the previous workspace.
    func workspacePrevious(_ params: [String: JSONValue]) -> ControlCallResult {
        workspaceNavigationResult(
            context?.controlSelectPreviousWorkspace(routing: routingSelectors(params)),
            notFoundMessage: "No workspace selected"
        )
    }

    /// `workspace.last` — navigate to the previously-selected workspace.
    func workspaceLast(_ params: [String: JSONValue]) -> ControlCallResult {
        workspaceNavigationResult(
            context?.controlSelectLastWorkspace(routing: routingSelectors(params)),
            notFoundMessage: "No previous workspace in history"
        )
    }

    /// `workspace.last_forward` — navigate forward in workspace history.
    func workspaceLastForward(_ params: [String: JSONValue]) -> ControlCallResult {
        workspaceNavigationResult(
            context?.controlSelectLastForwardWorkspace(routing: routingSelectors(params)),
            notFoundMessage: "No next workspace in history"
        )
    }

    // MARK: - Equalize

    /// `workspace.equalize_splits` — equalize the resolved workspace's splits.
    func workspaceEqualizeSplits(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = context?.controlEqualizeWorkspaceSplits(
            routing: routingSelectors(params),
            orientationFilter: string(params, "orientation")
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .notFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .resolved(let workspaceID, let equalized):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "equalized": .bool(equalized),
            ]))
        }
    }

    // MARK: - Remote

    /// Shapes the shared remote-mutation result for disconnect / reconnect /
    /// foreground_auth_ready / status.
    private func workspaceRemoteResult(_ resolution: ControlWorkspaceRemoteResolution?) -> ControlCallResult {
        switch resolution ?? .missingWorkspaceID {
        case .missingWorkspaceID:
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        case .notFound(let workspaceID):
            return .err(code: "not_found", message: "Workspace not found", data: .object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
            ]))
        case .notConfigured(let workspaceID):
            return .err(code: "invalid_state", message: "Remote workspace is not configured", data: .object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
            ]))
        case .unavailable(let workspaceID, let message):
            return .err(code: "unavailable", message: message, data: .object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
            ]))
        case .resolved(let windowID, let workspaceID, let remoteStatus):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "remote": remoteStatus,
            ]))
        }
    }

    /// Resolves the explicit-or-fallback workspace id for the remote methods,
    /// reproducing the legacy `requestedWorkspaceId ?? selectedTabId` rule and
    /// its two `invalid_params` failures.
    private func remoteWorkspaceID(
        _ params: [String: JSONValue]
    ) -> (workspaceID: UUID?, error: ControlCallResult?) {
        let requested = uuid(params, "workspace_id")
        if hasNonNull(params, "workspace_id"), requested == nil {
            return (nil, .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil))
        }
        let resolved = context?.controlResolveRemoteWorkspaceID(
            routing: routingSelectors(params),
            requestedWorkspaceID: requested
        )
        guard let resolved else {
            return (nil, .err(code: "invalid_params", message: "Missing workspace_id", data: nil))
        }
        return (resolved, nil)
    }

    /// `workspace.remote.configure` — configure a workspace's remote connection.
    func workspaceRemoteConfigure(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = remoteWorkspaceID(params)
        if let error = resolution.error { return error }
        guard let workspaceID = resolution.workspaceID else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }
        return context?.controlConfigureWorkspaceRemote(params: params, workspaceID: workspaceID)
            ?? .err(code: "not_found", message: "Workspace not found", data: .object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
            ]))
    }

    /// `workspace.remote.disconnect` — disconnect a workspace's remote.
    func workspaceRemoteDisconnect(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = remoteWorkspaceID(params)
        if let error = resolution.error { return error }
        guard let workspaceID = resolution.workspaceID else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }
        let clearConfiguration = bool(params, "clear") ?? false
        return workspaceRemoteResult(context?.controlDisconnectWorkspaceRemote(
            workspaceID: workspaceID,
            clearConfiguration: clearConfiguration
        ))
    }

    /// `workspace.remote.reconnect` — reconnect a workspace's remote.
    func workspaceRemoteReconnect(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = remoteWorkspaceID(params)
        if let error = resolution.error { return error }
        guard let workspaceID = resolution.workspaceID else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }
        let surfaceID = uuid(params, "surface_id")
        if hasNonNull(params, "surface_id"), surfaceID == nil {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        return workspaceRemoteResult(context?.controlReconnectWorkspaceRemote(
            workspaceID: workspaceID,
            surfaceID: surfaceID
        ))
    }

    /// `workspace.remote.foreground_auth_ready` — arm/continue a pending connect.
    func workspaceRemoteForegroundAuthReady(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = remoteWorkspaceID(params)
        if let error = resolution.error { return error }
        guard let workspaceID = resolution.workspaceID else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }
        guard let token = optionalTrimmedRawString(
            params,
            "foreground_auth_token"
        ) else {
            return .err(
                code: "invalid_params",
                message: "Missing foreground_auth_token",
                data: nil
            )
        }
        let controlPath = optionalTrimmedRawString(params, "control_path")
        return workspaceRemoteResult(context?.controlWorkspaceRemoteForegroundAuthReady(
            workspaceID: workspaceID,
            foregroundAuthToken: token,
            resolvedControlPath: controlPath
        ))
    }

    /// `workspace.remote.status` — read a workspace's remote status.
    func workspaceRemoteStatus(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = remoteWorkspaceID(params)
        if let error = resolution.error { return error }
        guard let workspaceID = resolution.workspaceID else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }
        return workspaceRemoteResult(context?.controlWorkspaceRemoteStatus(workspaceID: workspaceID))
    }

    /// `workspace.remote.pty_attach_end` — record a remote PTY attach end.
    func workspaceRemotePTYAttachEnd(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let workspaceID = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let surfaceID = uuid(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        guard let sessionID = optionalTrimmedRawString(params, "session_id") else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }

        let resolution = context?.controlWorkspaceRemotePTYAttachEnd(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            sessionID: sessionID
        ) ?? .notFound
        switch resolution {
        case .notFound:
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "session_id": .string(sessionID),
                "workspace_found": .bool(false),
                "cleared_remote_pty_session": .bool(false),
                "untracked_remote_terminal": .bool(false),
            ]))
        case .resolved(let windowID, let resolvedWorkspaceID, let cleared, let untracked, let remoteStatus):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(resolvedWorkspaceID.uuidString),
                "workspace_ref": ref(.workspace, resolvedWorkspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "session_id": .string(sessionID),
                "workspace_found": .bool(true),
                "cleared_remote_pty_session": .bool(cleared),
                "untracked_remote_terminal": .bool(untracked),
                "remote": remoteStatus,
            ]))
        }
    }

    /// `v2HasNonNullParam`-style null test on a typed value.
    private func isNull(_ value: JSONValue) -> Bool {
        if case .null = value { return true }
        return false
    }
}

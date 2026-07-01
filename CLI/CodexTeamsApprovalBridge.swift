import Foundation

enum CodexTeamsApprovalBridge {
    private typealias CodexPermissionCapabilities = (supportsOnce: Bool, supportsAlways: Bool, supportsAll: Bool)

    static func feedEvent(
        method: String,
        requestId: Any,
        params: [String: Any],
        workspaceId: String,
        relatedItem: [String: Any]? = nil
    ) -> [String: Any] {
        let threadId = stringValue(in: params, keys: ["threadId", "thread_id"])
            ?? stringValue(in: params, keys: ["threadID", "thread_id"])
            ?? "unknown"
        let turnId = stringValue(in: params, keys: ["turnId", "turn_id"])
        let itemId = stringValue(in: params, keys: ["approvalId", "approval_id", "itemId", "item_id"])
            ?? requestIdString(requestId)
        let cwd = stringValue(in: params, keys: ["cwd"])
        let reason = stringValue(in: params, keys: ["reason"])
        let command = stringValue(in: params, keys: ["command"])
        let toolName: String
        switch method {
        case "item/fileChange/requestApproval":
            toolName = "Write"
        case "item/permissions/requestApproval":
            toolName = "request_permissions"
        default:
            toolName = "Bash"
        }
        var toolInput: [String: Any] = [
            "app_server_method": method,
            "request_id": requestIdString(requestId),
            "item_id": itemId,
            "approval_params": approvalParamsSnapshot(params)
        ]
        if let turnId { toolInput["turn_id"] = turnId }
        if let reason { toolInput["reason"] = reason }
        if let command { toolInput["command"] = command }
        if let cwd { toolInput["cwd"] = cwd }
        if let approvalId = stringValue(in: params, keys: ["approvalId", "approval_id"]) {
            toolInput["approval_id"] = approvalId
        }
        setBoundedToolInput(&toolInput, key: "grant_root", value: params["grantRoot"] ?? params["grant_root"])
        if let available = params["availableDecisions"] ?? params["available_decisions"] {
            toolInput["available_decisions"] = decisionNames(available)
        }
        setBoundedToolInput(&toolInput, key: "permissions", value: params["permissions"])
        setBoundedToolInput(&toolInput, key: "network_approval_context", value: params["networkApprovalContext"] ?? params["network_approval_context"])
        setBoundedToolInput(&toolInput, key: "additional_permissions", value: params["additionalPermissions"] ?? params["additional_permissions"])
        setBoundedToolInput(&toolInput, key: "command_actions", value: params["commandActions"] ?? params["command_actions"])
        setBoundedToolInput(&toolInput, key: "proposed_execpolicy_amendment", value: params["proposedExecpolicyAmendment"] ?? params["proposed_execpolicy_amendment"])
        setBoundedToolInput(&toolInput, key: "proposed_network_policy_amendments", value: params["proposedNetworkPolicyAmendments"] ?? params["proposed_network_policy_amendments"])
        if let relatedItem {
            toolInput["related_item"] = relatedItem
            if command == nil,
               let relatedCommand = relatedItem["command"] as? String {
                toolInput["command"] = relatedCommand
            }
            if cwd == nil,
               let relatedCwd = relatedItem["cwd"] as? String {
                toolInput["cwd"] = relatedCwd
            }
        }

        var context: [String: Any] = [
            "permissionMode": "codex app-server"
        ]
        if let reason {
            context["assistantPreamble"] = reason
        }
        if let command {
            context["toolSummary"] = command
        }

        var event: [String: Any] = [
            "session_id": "codex-\(threadId)",
            "hook_event_name": "PermissionRequest",
            "_source": "codex",
            "workspace_id": workspaceId,
            "tool_name": toolName,
            "tool_input": toolInput,
            "context": context,
            "_opencode_request_id": "codex-app-server-\(itemId)"
        ]
        if let cwd { event["cwd"] = cwd }
        return event
    }

    static func permissionMode(fromFeedPushResponse response: [String: Any]) -> String? {
        guard (response["status"] as? String) == "resolved",
              let decision = response["decision"] as? [String: Any],
              (decision["kind"] as? String) == "permission",
              let mode = decision["mode"] as? String
        else { return nil }
        return mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func appServerApprovalResponse(
        method: String,
        params: [String: Any],
        mode: String
    ) -> [String: Any]? {
        switch method {
        case "item/commandExecution/requestApproval":
            return ["decision": commandApprovalDecision(params: params, mode: mode)]
        case "item/fileChange/requestApproval":
            return ["decision": fileChangeApprovalDecision(params: params, mode: mode)]
        case "item/permissions/requestApproval":
            return permissionsApprovalResponse(params: params, mode: mode)
        default:
            return nil
        }
    }

    static func approvalItemSnapshot(_ item: [String: Any]) -> [String: Any] {
        var snapshot: [String: Any] = [:]
        for key in ["id", "type", "threadId", "thread_id", "turnId", "turn_id", "command", "cwd", "path", "status"] {
            if let value = item[key],
               let bounded = boundedApprovalItemValue(value) {
                snapshot[key] = bounded
            }
        }
        if let changes = item["changes"] as? [[String: Any]] {
            snapshot["changes"] = changes.prefix(20).map { change in
                var changeSnapshot: [String: Any] = [:]
                for key in ["path", "kind", "type", "status", "diff", "summary"] {
                    if let value = change[key],
                       let bounded = boundedApprovalItemValue(value) {
                        changeSnapshot[key] = bounded
                    }
                }
                return changeSnapshot
            }
        }
        return snapshot
    }

    static func resolvedWorkingDirectory(
        commandArgs: [String],
        baseDirectory: String
    ) -> String? {
        let valueOptions: Set<String> = ["-C", "--cd", "--cwd"]
        let optionPrefixes = valueOptions.map { "\($0)=" }
        var index = 0
        var requested: String?
        while index < commandArgs.count {
            let arg = commandArgs[index]
            if arg == "--" { break }
            if valueOptions.contains(arg), index + 1 < commandArgs.count {
                requested = commandArgs[index + 1]
                index += 2
                continue
            }
            if let prefix = optionPrefixes.first(where: { arg.hasPrefix($0) }) {
                requested = String(arg.dropFirst(prefix.count))
            }
            index += 1
        }
        guard let requested = requested?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requested.isEmpty else {
            return nil
        }
        let expanded = (requested as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        return URL(
            fileURLWithPath: expanded,
            relativeTo: URL(fileURLWithPath: baseDirectory, isDirectory: true)
        ).standardizedFileURL.path
    }

    static func validateWorkingDirectory(
        commandArgs: [String],
        baseDirectory: String
    ) throws {
        guard let cwd = resolvedWorkingDirectory(
            commandArgs: commandArgs,
            baseDirectory: baseDirectory
        ) else {
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw validationError("cmux codex-teams cwd does not exist: \(cwd)")
        }
    }

    private static func validationError(_ message: String) -> NSError {
        NSError(
            domain: "CodexTeamsApprovalBridge",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    static func feedSourceSupportsPersistentPermissionModes(_ source: String) -> Bool {
        source != "hermes-agent"
    }

    static func feedSourceSupportsOncePermissionMode(_ source: String, toolInputJSON: String?) -> Bool {
        guard source == "codex" else { return true }
        return codexCapabilities(toolInputJSON: toolInputJSON).supportsOnce
    }

    static func feedSourceSupportsAlwaysPermissionMode(_ source: String, toolInputJSON: String?) -> Bool {
        guard feedSourceSupportsPersistentPermissionModes(source) else { return false }
        guard source == "codex" else { return true }
        return codexCapabilities(toolInputJSON: toolInputJSON).supportsAlways
    }

    static func feedSourceSupportsAllPermissionMode(_ source: String, toolInputJSON: String?) -> Bool {
        guard feedSourceSupportsPersistentPermissionModes(source) else { return false }
        guard source == "codex" else { return true }
        return codexCapabilities(toolInputJSON: toolInputJSON).supportsAll
    }

    static func feedSourceSupportsBypassPermissions(_ source: String) -> Bool {
        source != "codex" && source != "claude" && source != "hermes-agent"
    }

    static func requestIdString(_ requestId: Any) -> String {
        if let string = requestId as? String {
            return string
        }
        if let number = requestId as? NSNumber {
            return number.stringValue
        }
        return String(describing: requestId)
    }

    static func stringValue(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            } else if let value = object[key] as? NSNumber {
                return value.stringValue
            }
        }
        return nil
    }

    private static func commandApprovalDecision(params: [String: Any], mode: String) -> Any {
        if mode == "deny" { return rejectApprovalDecision(params: params) }
        if mode == "all" || mode == "bypass",
           let decision = commandApprovalAmendmentDecision(params: params) {
            return decision
        }
        if mode == "all" || mode == "bypass" {
            if decisionAvailableOrUnspecified("accept", params: params) {
                return "accept"
            }
            return rejectApprovalDecision(params: params)
        }
        if modeRequestsPersistentApproval(mode),
           decisionAvailableOrUnspecified("acceptForSession", params: params) {
            return "acceptForSession"
        }
        if modeRequestsPersistentApproval(mode),
           let decision = commandApprovalAmendmentDecision(params: params) {
            return decision
        }
        if modeRequestsPersistentApproval(mode) {
            if decisionAvailableOrUnspecified("accept", params: params) {
                return "accept"
            }
            return rejectApprovalDecision(params: params)
        }
        guard mode == "once" else {
            return rejectApprovalDecision(params: params)
        }
        if decisionAvailableOrUnspecified("accept", params: params) {
            return "accept"
        }
        return rejectApprovalDecision(params: params)
    }

    private static func commandApprovalAmendmentDecision(params: [String: Any]) -> Any? {
        if decisionAvailableOrUnspecified("acceptWithExecpolicyAmendment", params: params),
           let amendment = params["proposedExecpolicyAmendment"] ?? params["proposed_execpolicy_amendment"] {
            return [
                "acceptWithExecpolicyAmendment": [
                    "execpolicy_amendment": amendment
                ]
            ]
        }
        if decisionAvailableOrUnspecified("applyNetworkPolicyAmendment", params: params),
           let amendments = (params["proposedNetworkPolicyAmendments"] as? [Any])
                ?? (params["proposed_network_policy_amendments"] as? [Any]),
           let amendment = amendments.first {
            return [
                "applyNetworkPolicyAmendment": [
                    "network_policy_amendment": amendment
                ]
            ]
        }
        return nil
    }

    private static func boundedApprovalItemValue(_ value: Any) -> Any? {
        if let string = value as? String {
            let limit = 4_096
            guard string.count > limit else { return string }
            let index = string.index(string.startIndex, offsetBy: limit)
            return String(string[..<index])
        }
        if value is NSNumber || value is Bool || value is NSNull {
            return value
        }
        return nil
    }

    private static func approvalParamsSnapshot(_ params: [String: Any]) -> [String: Any] {
        let keys = [
            "threadId",
            "thread_id",
            "turnId",
            "turn_id",
            "itemId",
            "item_id",
            "approvalId",
            "approval_id",
            "environmentId",
            "environment_id",
            "cwd",
            "reason",
            "command",
            "grantRoot",
            "grant_root",
            "availableDecisions",
            "available_decisions",
            "permissions",
            "networkApprovalContext",
            "network_approval_context",
            "additionalPermissions",
            "additional_permissions",
            "commandActions",
            "command_actions",
            "proposedExecpolicyAmendment",
            "proposed_execpolicy_amendment",
            "proposedNetworkPolicyAmendments",
            "proposed_network_policy_amendments"
        ]
        var snapshot: [String: Any] = [:]
        for key in keys {
            guard let value = params[key],
                  let bounded = boundedApprovalParamValue(value, depth: 0) else {
                continue
            }
            snapshot[key] = bounded
        }
        return snapshot
    }

    private static func setBoundedToolInput(_ toolInput: inout [String: Any], key: String, value: Any?) {
        guard let value,
              let bounded = boundedApprovalParamValue(value, depth: 0) else {
            return
        }
        toolInput[key] = bounded
    }

    private static func boundedApprovalParamValue(_ value: Any, depth: Int) -> Any? {
        let stringLimit = 4_096
        let collectionLimit = 50
        guard depth <= 5 else { return nil }

        if let string = value as? String {
            guard string.count > stringLimit else { return string }
            let index = string.index(string.startIndex, offsetBy: stringLimit)
            return String(string[..<index])
        }
        if value is NSNumber || value is Bool || value is NSNull {
            return value
        }
        if let array = value as? [Any] {
            return array.prefix(collectionLimit).compactMap {
                boundedApprovalParamValue($0, depth: depth + 1)
            }
        }
        if let object = value as? [String: Any] {
            var snapshot: [String: Any] = [:]
            for key in object.keys.sorted().prefix(collectionLimit) {
                guard let value = object[key],
                      let bounded = boundedApprovalParamValue(value, depth: depth + 1) else {
                    continue
                }
                snapshot[key] = bounded
            }
            return snapshot
        }
        return nil
    }

    private static func fileChangeApprovalDecision(params: [String: Any], mode: String) -> String {
        if mode == "deny" { return rejectApprovalDecision(params: params) }
        if modeRequestsPersistentApproval(mode)
            && decisionAvailableOrUnspecified("acceptForSession", params: params) {
            return "acceptForSession"
        }
        if modeRequestsPersistentApproval(mode) {
            if decisionAvailableOrUnspecified("accept", params: params) {
                return "accept"
            }
            return rejectApprovalDecision(params: params)
        }
        guard mode == "once" else {
            return rejectApprovalDecision(params: params)
        }
        if decisionAvailableOrUnspecified("accept", params: params) {
            return "accept"
        }
        return rejectApprovalDecision(params: params)
    }

    private static func permissionsApprovalResponse(params: [String: Any], mode: String) -> [String: Any] {
        if mode == "deny" {
            return [
                "permissions": [String: Any](),
                "scope": "turn"
            ]
        }
        guard mode == "once" || modeRequestsPersistentApproval(mode) else {
            return [
                "permissions": [String: Any](),
                "scope": "turn"
            ]
        }
        return [
            "permissions": params["permissions"] ?? [String: Any](),
            "scope": modeRequestsPersistentApproval(mode) ? "session" : "turn"
        ]
    }

    private static func modeRequestsPersistentApproval(_ mode: String) -> Bool {
        mode == "always" || mode == "all" || mode == "bypass"
    }

    private static func availableDecisions(_ params: [String: Any]) -> Set<String> {
        guard let raw = params["availableDecisions"] ?? params["available_decisions"] else {
            return []
        }
        return Set(decisionNames(raw))
    }

    private static func decisionAvailableOrUnspecified(_ decision: String, params: [String: Any]) -> Bool {
        guard params["availableDecisions"] != nil || params["available_decisions"] != nil else {
            return true
        }
        return availableDecisions(params).contains(decision)
    }

    private static func rejectApprovalDecision(params: [String: Any]) -> String {
        let available = availableDecisions(params)
        if available.contains("decline") || available.isEmpty {
            return "decline"
        }
        if available.contains("cancel") {
            return "cancel"
        }
        return "decline"
    }

    private static func decisionNames(_ raw: Any) -> [String] {
        let values = raw as? [Any] ?? []
        return values.compactMap { value in
            if let string = value as? String {
                return string
            }
            if let object = value as? [String: Any],
               let key = object.keys.first {
                return key
            }
            return nil
        }
    }

    private static func codexCapabilities(toolInputJSON: String?) -> CodexPermissionCapabilities {
        guard let toolInputJSON else {
            return (supportsOnce: true, supportsAlways: true, supportsAll: true)
        }
        guard let data = toolInputJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return (supportsOnce: false, supportsAlways: false, supportsAll: false)
        }

        let method = object["app_server_method"] as? String
        let decisions = codexAvailableDecisions(in: object)
        let acceptsOnce = decisions?.contains("accept") ?? true
        let acceptsSession = decisions?.contains("acceptForSession") ?? true
        switch method {
        case "item/permissions/requestApproval":
            return (supportsOnce: true, supportsAlways: true, supportsAll: true)
        case "item/commandExecution/requestApproval":
            return (
                supportsOnce: acceptsOnce,
                supportsAlways: acceptsSession,
                supportsAll: codexSupportsAmendmentDecision(object: object, decisions: decisions)
            )
        case "item/fileChange/requestApproval":
            return (
                supportsOnce: acceptsOnce,
                supportsAlways: acceptsSession,
                supportsAll: false
            )
        default:
            return (supportsOnce: acceptsOnce, supportsAlways: acceptsSession, supportsAll: false)
        }
    }

    private static func codexSupportsAmendmentDecision(object: [String: Any], decisions: Set<String>?) -> Bool {
        if let amendment = object["proposed_execpolicy_amendment"],
           codexDecisionAvailableOrUnspecified("acceptWithExecpolicyAmendment", decisions: decisions),
           !(amendment is NSNull) {
            return true
        }
        if let amendments = object["proposed_network_policy_amendments"] as? [Any],
           !amendments.isEmpty,
           codexDecisionAvailableOrUnspecified("applyNetworkPolicyAmendment", decisions: decisions) {
            return true
        }
        return false
    }

    private static func codexAvailableDecisions(in object: [String: Any]) -> Set<String>? {
        guard let raw = object["available_decisions"] ?? object["availableDecisions"] else {
            return nil
        }
        return Set(decisionNames(raw))
    }

    private static func codexDecisionAvailableOrUnspecified(_ decision: String, decisions: Set<String>?) -> Bool {
        decisions?.contains(decision) ?? true
    }
}

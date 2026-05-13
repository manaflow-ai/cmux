import Foundation

extension CMUXCLI {
    func agentFastPathWorkspaceArg(
        workspaceRaw: String?,
        windowOverride: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        workspaceRaw ?? (windowOverride == nil ? environment["CMUX_WORKSPACE_ID"] : nil)
    }

    func agentFastPathWorkspaceParams(
        workspaceRaw: String?,
        client: SocketClient,
        windowOverride: String?
    ) throws -> [String: Any] {
        let workspaceArg = agentFastPathWorkspaceArg(
            workspaceRaw: workspaceRaw,
            windowOverride: windowOverride
        )
        var params: [String: Any] = [:]
        let workspaceId = try normalizeWorkspaceHandle(workspaceArg, client: client)
        if let workspaceId {
            params["workspace_id"] = workspaceId
        }
        return params
    }

    func agentFastPathTargetParams(
        workspaceRaw: String?,
        surfaceRaw: String?,
        client: SocketClient,
        windowOverride: String?
    ) throws -> [String: Any] {
        let env = ProcessInfo.processInfo.environment
        let workspaceArg = agentFastPathWorkspaceArg(
            workspaceRaw: workspaceRaw,
            windowOverride: windowOverride,
            environment: env
        )
        let surfaceArg = surfaceRaw ?? (workspaceRaw == nil && windowOverride == nil ? env["CMUX_SURFACE_ID"] : nil)

        var params: [String: Any] = [:]
        let workspaceId = try normalizeWorkspaceHandle(workspaceArg, client: client)
        if let workspaceId {
            params["workspace_id"] = workspaceId
        }
        let surfaceId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: workspaceId)
        if let surfaceId {
            params["surface_id"] = surfaceId
        }
        return params
    }

    func agentFastPathCapturePayload(
        workspaceRaw: String?,
        surfaceRaw: String?,
        scrollback: Bool,
        lines: Int?,
        client: SocketClient,
        windowOverride: String?
    ) throws -> [String: Any] {
        var params = try agentFastPathTargetParams(
            workspaceRaw: workspaceRaw,
            surfaceRaw: surfaceRaw,
            client: client,
            windowOverride: windowOverride
        )
        if scrollback {
            params["scrollback"] = true
        }
        if let lines {
            params["lines"] = lines
            params["scrollback"] = true
        }
        return try client.sendV2(method: "surface.read_text", params: params)
    }

    func agentFastPathSendPayload(
        workspaceRaw: String?,
        surfaceRaw: String?,
        text: String,
        appendEnter: Bool,
        client: SocketClient,
        windowOverride: String?
    ) throws -> [String: Any] {
        var params = try agentFastPathTargetParams(
            workspaceRaw: workspaceRaw,
            surfaceRaw: surfaceRaw,
            client: client,
            windowOverride: windowOverride
        )
        params["text"] = appendEnter ? text + "\r" : text
        return try client.sendV2(method: "surface.send_text", params: params)
    }

    func agentFastPathSendKeyPayload(
        workspaceRaw: String?,
        surfaceRaw: String?,
        key: String,
        client: SocketClient,
        windowOverride: String?
    ) throws -> [String: Any] {
        var params = try agentFastPathTargetParams(
            workspaceRaw: workspaceRaw,
            surfaceRaw: surfaceRaw,
            client: client,
            windowOverride: windowOverride
        )
        params["key"] = key
        return try client.sendV2(method: "surface.send_key", params: params)
    }

    func agentFastPathListPayload(
        method: String,
        workspaceRaw: String?,
        client: SocketClient,
        windowOverride: String?
    ) throws -> [String: Any] {
        let params = try agentFastPathWorkspaceParams(
            workspaceRaw: workspaceRaw,
            client: client,
            windowOverride: windowOverride
        )
        return try client.sendV2(method: method, params: params)
    }

    func agentFastPathListPanesPayload(
        workspaceRaw: String?,
        client: SocketClient,
        windowOverride: String?
    ) throws -> [String: Any] {
        try agentFastPathListPayload(
            method: "pane.list",
            workspaceRaw: workspaceRaw,
            client: client,
            windowOverride: windowOverride
        )
    }

    func agentFastPathListSurfacesPayload(
        workspaceRaw: String?,
        client: SocketClient,
        windowOverride: String?
    ) throws -> [String: Any] {
        try agentFastPathListPayload(
            method: "surface.list",
            workspaceRaw: workspaceRaw,
            client: client,
            windowOverride: windowOverride
        )
    }
}

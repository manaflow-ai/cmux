import Foundation

extension CMUXCLI {
    func socketSurfaceOption(_ surfaceId: String?) -> String {
        guard let surfaceId = nonEmptyClaudeHookIdentifier(surfaceId) else { return "" }
        return " --surface=\(surfaceId)"
    }

    func setClaudeStatus(
        client: SocketClient,
        workspaceId: String,
        surfaceId: String? = nil,
        value: String,
        icon: String,
        color: String,
        pid: Int? = nil
    ) throws {
        var cmd = "set_status claude_code \(value) --icon=\(icon) --color=\(color) --tab=\(workspaceId)"
        if let pid { cmd += " --pid=\(pid)" }
        cmd += socketSurfaceOption(surfaceId)
        _ = try client.send(command: cmd)
    }

    func clearClaudeStatus(client: SocketClient, workspaceId: String, surfaceId: String? = nil) throws {
        _ = try client.send(command: "clear_status claude_code --tab=\(workspaceId)\(socketSurfaceOption(surfaceId))")
    }

    func resolvePreferredWorkspaceIdForClaudeHook(
        preferred: String?,
        fallback: String?,
        client: SocketClient
    ) throws -> String {
        if let preferred = nonEmptyClaudeHookIdentifier(preferred) {
            return try resolveWorkspaceIdForClaudeHook(preferred, client: client)
        }
        if let fallback = nonEmptyClaudeHookIdentifier(fallback) {
            return try resolveWorkspaceIdForClaudeHook(fallback, client: client)
        }
        return try resolveWorkspaceIdForClaudeHook(nil, client: client)
    }

    func resolvePreferredSurfaceIdForClaudeHook(
        preferred: String?,
        fallback: String?,
        workspaceId: String,
        client: SocketClient
    ) throws -> String {
        if let preferred = nonEmptyClaudeHookIdentifier(preferred) {
            return try resolveSurfaceIdForClaudeHook(preferred, workspaceId: workspaceId, client: client)
        }
        if let fallback = nonEmptyClaudeHookIdentifier(fallback) {
            return try resolveSurfaceIdForClaudeHook(fallback, workspaceId: workspaceId, client: client)
        }
        return try resolveSurfaceIdForClaudeHook(nil, workspaceId: workspaceId, client: client)
    }

    func resolveOptionalWorkspaceIdForClaudeHook(
        preferred: String?,
        fallback: String?,
        client: SocketClient
    ) -> String? {
        try? resolvePreferredWorkspaceIdForClaudeHook(preferred: preferred, fallback: fallback, client: client)
    }

    func resolveOptionalSurfaceIdForClaudeHook(
        preferred: String?,
        fallback: String?,
        workspaceId: String,
        client: SocketClient
    ) -> String? {
        try? resolvePreferredSurfaceIdForClaudeHook(preferred: preferred, fallback: fallback, workspaceId: workspaceId, client: client)
    }

    func nonEmptyClaudeHookIdentifier(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

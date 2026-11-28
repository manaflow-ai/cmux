extension ControlCommandCoordinator {
    /// Local terminal details, excluded from relay-scoped surface.list responses.
    nonisolated func surfaceTerminalMetadata(_ surface: ControlSurfaceSummary) -> [String: JSONValue] {
        var item: [String: JSONValue] = [:]
        item["requested_working_directory"] = orNull(surface.requestedWorkingDirectory)
        item["initial_command"] = orNull(surface.initialCommand)
        item["tmux_start_command"] = orNull(surface.tmuxStartCommand)
        item["resume_binding"] = surfaceResumeBindingPayload(surface.resumeBinding)
        item["render_health"] = orNull(surface.renderHealthRawValue)
        item["tty"] = orNull(surface.controllingTTY)
        item["foreground_pid"] = surface.foregroundProcessID.map { .int(Int64($0)) } ?? .null
        return item
    }
}

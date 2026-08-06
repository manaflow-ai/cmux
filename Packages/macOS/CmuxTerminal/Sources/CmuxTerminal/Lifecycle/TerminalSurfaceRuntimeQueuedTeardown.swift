// Safety: the request transports retained native userdata and is consumed by
// exactly one serialized worker before its main-actor cleanup runs.
struct TerminalSurfaceRuntimeQueuedTeardown: @unchecked Sendable {
    let request: TerminalSurfaceRuntimeTeardownRequest
    let hibernationReservation: TerminalSurfaceRuntimeTeardownReservation?
}

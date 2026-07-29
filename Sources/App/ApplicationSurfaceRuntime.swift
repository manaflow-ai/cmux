@MainActor
protocol ApplicationSurfaceRuntime: AnyObject {
    func acquireApplicationSurfaceLease() async -> ApplicationSurfaceRuntimeLease?
    func listApplicationWindows(
        lease: ApplicationSurfaceRuntimeLease
    ) async throws -> [ApplicationWindowDescriptor]
    func startApplicationSurface(
        lease: ApplicationSurfaceRuntimeLease,
        windowID: UInt32,
        processID: Int32,
        frameRate: Int
    ) async throws -> ApplicationSurfaceSessionDescriptor
    func stopApplicationSurface(
        lease: ApplicationSurfaceRuntimeLease,
        sessionID: String
    ) async
    func checkApplicationSurfaceHealth(
        lease: ApplicationSurfaceRuntimeLease,
        sessionID: String
    ) async throws
    func sendApplicationSurfaceEvent(
        lease: ApplicationSurfaceRuntimeLease,
        sessionID: String,
        event: ApplicationSurfaceInputEvent
    ) async throws
    func sendApplicationSurfaceEvents(
        lease: ApplicationSurfaceRuntimeLease,
        sessionID: String,
        events: [ApplicationSurfaceInputEvent]
    ) async throws
}

extension ApplicationSurfaceRuntime {
    func sendApplicationSurfaceEvents(
        lease: ApplicationSurfaceRuntimeLease,
        sessionID: String,
        events: [ApplicationSurfaceInputEvent]
    ) async throws {
        for event in events {
            try await sendApplicationSurfaceEvent(
                lease: lease,
                sessionID: sessionID,
                event: event
            )
        }
    }
}

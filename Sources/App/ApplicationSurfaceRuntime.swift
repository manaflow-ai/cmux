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
        processIdentity: ApplicationSurfaceProcessIdentity?,
        frameRate: Int
    ) async throws -> ApplicationSurfaceSessionDescriptor
    func stopApplicationSurface(
        lease: ApplicationSurfaceRuntimeLease,
        sessionID: String
    ) async
    func acknowledgeApplicationSurfaceAttachment(
        lease: ApplicationSurfaceRuntimeLease,
        sessionID: String
    ) async throws
    func applicationSurfaceFailureEvents(
        lease: ApplicationSurfaceRuntimeLease,
        sessionID: String
    ) -> AsyncStream<ApplicationSurfaceRuntimeError>
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
    func applicationSurfaceFailureEvents(
        lease: ApplicationSurfaceRuntimeLease,
        sessionID: String
    ) -> AsyncStream<ApplicationSurfaceRuntimeError> {
        _ = lease
        _ = sessionID
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

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

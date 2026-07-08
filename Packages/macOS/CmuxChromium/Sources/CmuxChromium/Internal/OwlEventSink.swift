import COwlFreshRuntime

/// Bridges the runtime's C event callback into an `AsyncStream` of session events.
///
/// A retained pointer to the sink is the callback's `user_data`; the retain is
/// balanced after the session is destroyed on the runtime thread.
final class OwlEventSink: Sendable {
    let continuation: AsyncStream<ChromiumSessionEvent>.Continuation

    init(continuation: AsyncStream<ChromiumSessionEvent>.Continuation) {
        self.continuation = continuation
    }

    /// C trampoline the runtime callback API forces on us; copies event data and yields it.
    static let trampoline: OwlFreshMojoEventCallback = { eventPointer, userData in
        guard let eventPointer, let userData else { return }
        let sink = Unmanaged<OwlEventSink>.fromOpaque(userData).takeUnretainedValue()
        guard let event = ChromiumSessionEvent(cEvent: eventPointer.pointee) else { return }
        sink.continuation.yield(event)
        if case .disconnected = event {
            sink.continuation.finish()
        }
    }
}

extension ChromiumSessionEvent {
    /// Copies a C runtime event into an owned Swift value; the C strings are
    /// only valid for the duration of the callback.
    init?(cEvent: OwlFreshMojoEvent) {
        switch cEvent.kind {
        case kOwlFreshMojoEventReady:
            self = .ready(hostPID: cEvent.host_pid, compositorContextID: cEvent.context_id)
        case kOwlFreshMojoEventCompositor:
            self = .compositorChanged(contextID: cEvent.context_id)
        case kOwlFreshMojoEventNavigation:
            self = .navigationChanged(
                url: cEvent.url.map { String(cString: $0) } ?? "",
                title: cEvent.title.map { String(cString: $0) } ?? "",
                isLoading: cEvent.loading
            )
        case kOwlFreshMojoEventSurfaceTree:
            self = .surfaceTreeChanged(json: cEvent.message.map { String(cString: $0) } ?? "")
        case kOwlFreshMojoEventLog:
            self = .log(cEvent.message.map { String(cString: $0) } ?? "")
        case kOwlFreshMojoEventDisconnected:
            self = .disconnected
        default:
            return nil
        }
    }
}

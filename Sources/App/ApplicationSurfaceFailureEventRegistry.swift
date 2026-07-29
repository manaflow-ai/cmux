@MainActor
final class ApplicationSurfaceFailureEventRegistry {
    private var continuations:
        [String: AsyncStream<ApplicationSurfaceRuntimeError>.Continuation] = [:]

    func events(
        for sessionID: String
    ) -> AsyncStream<ApplicationSurfaceRuntimeError> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations.removeValue(forKey: sessionID)?.finish()
            continuations[sessionID] = continuation
        }
    }

    func finish(sessionID: String) {
        continuations.removeValue(forKey: sessionID)?.finish()
    }

    func finishAll() {
        let activeContinuations = Array(continuations.values)
        continuations.removeAll()
        for continuation in activeContinuations {
            continuation.finish()
        }
    }

    func failAll(with error: ApplicationSurfaceRuntimeError) {
        let activeContinuations = Array(continuations.values)
        continuations.removeAll()
        for continuation in activeContinuations {
            continuation.yield(error)
            continuation.finish()
        }
    }
}

import Foundation

// Mutable registry state is confined to `queue`; callers interact through async queue hops.
final class CodexTranscriptMonitorRegistry: @unchecked Sendable {
    static let shared = CodexTranscriptMonitorRegistry()

    private let queue = DispatchQueue(label: "com.cmux.codex-transcript-monitor", qos: .utility)
    private var monitorsBySessionId: [String: CodexTranscriptMonitorSession] = [:]

    private init() {}

    deinit {}

    func start(_ request: CodexTranscriptMonitorRequest) {
        queue.async { [weak self] in
            guard let self else { return }
            let key = request.sessionId
            self.monitorsBySessionId[key]?.cancel()
            let monitor = CodexTranscriptMonitorSession(
                request: request,
                queue: self.queue,
                onEvent: { [weak self] event in self?.publish(event) },
                onFinish: { [weak self] sessionId, monitor in
                    guard let self else { return }
                    if self.monitorsBySessionId[sessionId] === monitor {
                        self.monitorsBySessionId.removeValue(forKey: sessionId)
                    }
                }
            )
            self.monitorsBySessionId[key] = monitor
            monitor.start()
        }
    }

    func stop(sessionId: String, turnId: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            if let monitor = self.monitorsBySessionId[sessionId],
               turnId == nil || monitor.matches(turnId: turnId) {
                monitor.cancel()
                self.monitorsBySessionId.removeValue(forKey: sessionId)
            }
        }
    }

    func stopWorkspace(_ workspaceId: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            let matchingSessionIds = self.monitorsBySessionId.compactMap { sessionId, monitor in
                monitor.workspaceId == workspaceId ? sessionId : nil
            }
            for sessionId in matchingSessionIds {
                self.monitorsBySessionId[sessionId]?.cancel()
                self.monitorsBySessionId.removeValue(forKey: sessionId)
            }
        }
    }

    private func publish(_ event: CodexTranscriptMonitorEvent) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                TerminalController.shared.handleCodexTranscriptMonitorEvent(event)
            }
        }
    }
}

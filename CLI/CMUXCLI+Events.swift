import Foundation

struct EventStreamLimitReached: Error {}

extension CMUXCLI {
    func isTransientEventStreamError(_ error: Error) -> Bool {
        if let cliError = error as? CLIError {
            let message = cliError.message.lowercased()
            let transientMarkers = [
                "socket not found",
                "failed to connect",
                "event stream closed",
                "event stream socket read error",
                "timed out waiting for event stream frame",
                "stream request timed out",
                "failed to write stream request",
                "broken pipe",
                "connection reset",
                "connection refused",
                "errno 32",
                "errno 35",
                "errno 54",
                "errno 57",
                "errno 60",
                "errno 61"
            ]
            return transientMarkers.contains { message.contains($0) }
        }

        let description = String(describing: error).lowercased()
        return description.contains("connection reset")
            || description.contains("connection refused")
            || description.contains("broken pipe")
            || description.contains("timed out")
    }

    func waitBeforeReconnectingEventStream() {
        let semaphore = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "com.cmux.cli.events.reconnect-delay.\(UUID().uuidString)")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0)
        timer.setEventHandler {
            semaphore.signal()
        }
        timer.resume()
        semaphore.wait()
        timer.cancel()
    }
}

import CmuxSimulator
import Foundation
import os

extension SimulatorWorkerCoordinator {
    func reportUnavailable(action: String, detail: String) {
        let failure = SimulatorFailure(
            code: "\(action)_unavailable",
            message: detail,
            isRecoverable: true
        )
        send(.failure(failure))
        emitAction(action, summary: detail, succeeded: false)
    }

    func report(_ error: Error) {
        send(.failure(processSafeFailure(error)))
    }

    func report(_ error: Error, requestID: UUID) {
        send(.requestFailure(requestID: requestID, processSafeFailure(error)))
    }

    func processSafeFailure(_ error: Error) -> SimulatorFailure {
        if let error = error as? SimulatorWorkerFailure {
            return error.processSafeValue
        } else if let error = error as? SimulatorFailure {
            return error
        } else {
            return SimulatorFailure(
                code: "worker_action_failed",
                message: error.localizedDescription,
                isRecoverable: true
            )
        }
    }

    func send(_ message: SimulatorWorkerOutbound) {
        do {
            try channel.sendMessage(encoder.encode(message))
        } catch {
            coordinatorLogger.error("Simulator worker protocol write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func emitAction(_ action: String, summary: String, succeeded: Bool) {
        send(
            .actionLog(
                SimulatorActionLogEntry(
                    id: UUID(),
                    timestamp: Date(),
                    action: action,
                    summary: summary,
                    succeeded: succeeded
                )
            )
        )
    }

    static func accessibilityFrame(
        nodeIdentifier: String,
        nodes: [SimulatorAccessibilityNode]
    ) -> SimulatorRect? {
        for node in nodes {
            if node.id == nodeIdentifier { return node.frame }
            if let nested = accessibilityFrame(
                nodeIdentifier: nodeIdentifier,
                nodes: node.children
            ) {
                return nested
            }
        }
        return nil
    }

    static func accessibilityCoordinateSpace(
        nodes: [SimulatorAccessibilityNode]
    ) -> SimulatorRect? {
        var largest: SimulatorRect?
        var largestArea = 0.0
        for node in nodes {
            guard let frame = node.frame else { continue }
            let area = frame.width * frame.height
            guard frame.width > 0, frame.height > 0, area > largestArea else { continue }
            largest = frame
            largestArea = area
        }
        return largest
    }

    static func gestureSummary(
        start: SimulatorPoint,
        end: SimulatorPoint,
        twoFinger: Bool,
        cancelled: Bool
    ) -> String {
        let prefix = twoFinger ? "two-finger" : "touch"
        let state = cancelled ? "cancelled" : "ended"
        return String(
            format: "%@ %.3f,%.3f→%.3f,%.3f %@",
            prefix,
            start.x,
            start.y,
            end.x,
            end.y,
            state
        )
    }
}

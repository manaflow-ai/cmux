import CmuxControlSocket
import Foundation

/// Main-actor publication of the read-side control-plane mirror.
///
/// The publisher deliberately builds a small, stable set of topology reads
/// (without request ids) and swaps one immutable package snapshot. Socket
/// workers can then answer repeated list/tree polls without entering the main
/// actor; a mutation schedules one coalesced refresh on the next actor turn.
extension TerminalController {
    func scheduleSocketReadSnapshotRefresh() {
        guard socketReadSnapshotRefreshTask == nil else { return }
        socketReadSnapshotRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.publishSocketReadSnapshot()
            self.socketReadSnapshotRefreshTask = nil
        }
    }

    private func publishSocketReadSnapshot() {
        let requests: [ControlRequest] = [
            ControlRequest(id: nil, method: "window.list", params: [:]),
            ControlRequest(id: nil, method: "window.current", params: [:]),
            ControlRequest(id: nil, method: "window.displays", params: [:]),
            ControlRequest(id: nil, method: "workspace.list", params: [:]),
            ControlRequest(id: nil, method: "workspace.current", params: [:]),
            ControlRequest(id: nil, method: "surface.list", params: [:]),
            ControlRequest(id: nil, method: "surface.current", params: [:]),
            ControlRequest(id: nil, method: "pane.list", params: [:]),
            ControlRequest(id: nil, method: "pane.surfaces", params: [:]),
            ControlRequest(id: nil, method: "system.identify", params: [:]),
            ControlRequest(id: nil, method: "system.tree", params: [:]),
        ]
        var responses: [String: ControlCallResult] = [:]
        responses.reserveCapacity(requests.count)
        for request in requests {
            guard let result = controlCommandCoordinator.handleSocketWorkerV2(
                request,
                context: self
            ) else { continue }
            responses[ControlReadSnapshot.key(method: request.method, params: request.params)] = result
        }

        let nextGeneration = socketReadSnapshotStore.read().generation &+ 1
        socketReadSnapshotStore.publish(
            ControlReadSnapshot(generation: nextGeneration, responses: responses)
        )
    }
}

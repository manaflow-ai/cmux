import Foundation

struct RoutingTerminalInputRecord: Sendable {
    var surfaceID: String
    var text: String
}

actor TerminalRawInputTaskCompletionTracker {
    private var completionCount = 0

    func recordCompletion() {
        completionCount += 1
    }

    func recordedCompletionCount() -> Int { completionCount }
}

actor RoutingTerminalInputRecorder {
    private var inputs: [RoutingTerminalInputRecord] = []
    private var inFlightCount = 0
    private var maximumInFlightCount = 0
    private var holdFirstInput = false
    private var firstInputHeld = false
    private var firstInputContinuation: CheckedContinuation<Void, Never>?
    private var firstInputReachedWaiters: [CheckedContinuation<Void, Never>] = []

    func setHoldFirstInput(_ hold: Bool) {
        holdFirstInput = hold
    }

    func awaitFirstInputReached() async {
        if firstInputHeld { return }
        await withCheckedContinuation { firstInputReachedWaiters.append($0) }
    }

    func releaseFirstInput() {
        let continuation = firstInputContinuation
        firstInputContinuation = nil
        continuation?.resume()
    }

    func record(surfaceID: String, text: String) async {
        let index = inputs.count
        inputs.append(RoutingTerminalInputRecord(surfaceID: surfaceID, text: text))
        inFlightCount += 1
        maximumInFlightCount = max(maximumInFlightCount, inFlightCount)
        if index == 0 && holdFirstInput {
            firstInputHeld = true
            let reachedWaiters = firstInputReachedWaiters
            firstInputReachedWaiters = []
            for waiter in reachedWaiters { waiter.resume() }
            await withCheckedContinuation { firstInputContinuation = $0 }
        }
        inFlightCount -= 1
    }

    func recordedInputs() -> [RoutingTerminalInputRecord] { inputs }
    func recordedInFlightCount() -> Int { inFlightCount }
    func recordedMaximumInFlightCount() -> Int { maximumInFlightCount }
}

extension RoutingHostRouter {
    func setHoldFirstTerminalInput(_ hold: Bool) async {
        await terminalInputRecorder.setHoldFirstInput(hold)
    }

    func awaitFirstTerminalInputReached() async {
        await terminalInputRecorder.awaitFirstInputReached()
    }

    func releaseFirstTerminalInput() async {
        await terminalInputRecorder.releaseFirstInput()
    }

    func recordedTerminalInputs() async -> [RoutingTerminalInputRecord] {
        await terminalInputRecorder.recordedInputs()
    }

    func recordedTerminalInputInFlightCount() async -> Int {
        await terminalInputRecorder.recordedInFlightCount()
    }

    func recordedTerminalInputMaximumInFlightCount() async -> Int {
        await terminalInputRecorder.recordedMaximumInFlightCount()
    }

    func terminalInputResponse(_ info: RequestInfo) async -> Data? {
        let surfaceID = info.surfaceID ?? ""
        await terminalInputRecorder.record(surfaceID: surfaceID, text: info.text ?? "")
        return try? Self.resultFrame(id: info.id, result: [
            "workspace_id": Self.workspaceID,
            "surface_id": surfaceID,
            "queued": false,
        ])
    }
}

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
    private var holdAllInputs = false
    private var rejectInputAtIndex: Int?
    private var rejectInputCode = "terminal_input_failed"
    private var firstInputHeld = false
    private var firstInputContinuation: CheckedContinuation<Void, Never>?
    private var firstInputReachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var heldInputContinuations: [CheckedContinuation<Void, Never>] = []

    func setHoldFirstInput(_ hold: Bool) {
        holdFirstInput = hold
    }

    func setHoldAllInputs(_ hold: Bool) {
        holdAllInputs = hold
    }

    func setRejectInput(at index: Int?, code: String = "terminal_input_failed") {
        rejectInputAtIndex = index
        rejectInputCode = code
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

    func releaseAllInputs() {
        let continuations = heldInputContinuations
        heldInputContinuations = []
        for continuation in continuations {
            continuation.resume()
        }
    }

    func record(surfaceID: String, text: String) async -> Int {
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
        if holdAllInputs {
            await withCheckedContinuation {
                heldInputContinuations.append($0)
            }
        }
        inFlightCount -= 1
        return index
    }

    func recordedInputs() -> [RoutingTerminalInputRecord] { inputs }
    func recordedInFlightCount() -> Int { inFlightCount }
    func recordedMaximumInFlightCount() -> Int { maximumInFlightCount }
    func shouldReject(index: Int) -> Bool { rejectInputAtIndex == index }
    func rejectionCode() -> String { rejectInputCode }
}

extension RoutingHostRouter {
    func setHoldFirstTerminalInput(_ hold: Bool) async {
        await terminalInputRecorder.setHoldFirstInput(hold)
    }

    func awaitFirstTerminalInputReached() async {
        await terminalInputRecorder.awaitFirstInputReached()
    }

    func setHoldAllTerminalInputs(_ hold: Bool) async {
        await terminalInputRecorder.setHoldAllInputs(hold)
    }

    func setRejectTerminalInput(
        at index: Int?,
        code: String = "terminal_input_failed"
    ) async {
        await terminalInputRecorder.setRejectInput(at: index, code: code)
    }

    func releaseFirstTerminalInput() async {
        await terminalInputRecorder.releaseFirstInput()
    }

    func releaseAllTerminalInputs() async {
        await terminalInputRecorder.releaseAllInputs()
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
        let index = await terminalInputRecorder.record(
            surfaceID: surfaceID,
            text: info.text ?? ""
        )
        if await terminalInputRecorder.shouldReject(index: index) {
            return try? Self.errorFrame(
                id: info.id,
                code: await terminalInputRecorder.rejectionCode(),
                message: "terminal input rejected"
            )
        }
        return try? Self.resultFrame(id: info.id, result: [
            "workspace_id": Self.workspaceID,
            "surface_id": surfaceID,
            "queued": false,
        ])
    }
}

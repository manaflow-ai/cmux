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
    private struct CountWaiter {
        var expectedCount: Int
        var continuation: CheckedContinuation<Void, Never>
    }

    private var inputs: [RoutingTerminalInputRecord] = []
    private var inFlightCount = 0
    private var maximumInFlightCount = 0
    private var holdFirstInput = false
    private var holdAllInputs = false
    private var rejectInputAtIndex: Int?
    private var firstInputHeld = false
    private var firstInputContinuation: CheckedContinuation<Void, Never>?
    private var firstInputReachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var heldInputContinuations: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [UUID: CountWaiter] = [:]

    func setHoldFirstInput(_ hold: Bool) {
        holdFirstInput = hold
    }

    func setHoldAllInputs(_ hold: Bool) {
        holdAllInputs = hold
    }

    func setRejectInput(at index: Int?) {
        rejectInputAtIndex = index
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
        resumeSatisfiedCountWaiters()
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

    func waitForInputCount(
        atLeast expectedCount: Int,
        timeout: Duration
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.waitUntilInputCountReached(atLeast: expectedCount)
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let reached = await group.next() ?? false
            group.cancelAll()
            return reached
        }
    }

    private func waitUntilInputCountReached(atLeast expectedCount: Int) async {
        guard inputs.count < expectedCount else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                countWaiters[waiterID] = CountWaiter(
                    expectedCount: expectedCount,
                    continuation: continuation
                )
                resumeSatisfiedCountWaiters()
            }
        } onCancel: {
            Task { await self.cancelCountWaiter(id: waiterID) }
        }
    }

    private func resumeSatisfiedCountWaiters() {
        let satisfiedIDs = countWaiters.compactMap { id, waiter in
            inputs.count >= waiter.expectedCount ? id : nil
        }
        for id in satisfiedIDs {
            countWaiters.removeValue(forKey: id)?.continuation.resume()
        }
    }

    private func cancelCountWaiter(id: UUID) {
        countWaiters.removeValue(forKey: id)?.continuation.resume()
    }
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

    func setRejectTerminalInput(at index: Int?) async {
        await terminalInputRecorder.setRejectInput(at: index)
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

    func waitForTerminalInputCount(
        atLeast expectedCount: Int,
        timeout: Duration
    ) async -> Bool {
        await terminalInputRecorder.waitForInputCount(
            atLeast: expectedCount,
            timeout: timeout
        )
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
                code: "terminal_input_failed",
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

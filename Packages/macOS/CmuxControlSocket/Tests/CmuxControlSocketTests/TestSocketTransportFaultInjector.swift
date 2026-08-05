import os

@testable import CmuxControlSocket

/// Deterministic transport fault script used to exercise listener recovery
/// through the real server lifecycle and real Unix-domain sockets.
final class TestSocketTransportFaultInjector: SocketTransportFaultInjecting, Sendable {
    private let state: OSAllocatedUnfairLock<(
        failuresByStage: [String: [Int32]],
        repeatingFailuresByStage: [String: Int32],
        invocationCounts: [String: Int]
    )>

    init(
        failuresByStage: [String: [Int32]] = [:],
        repeatingFailuresByStage: [String: Int32] = [:]
    ) {
        state = OSAllocatedUnfairLock(initialState: (
            failuresByStage: failuresByStage,
            repeatingFailuresByStage: repeatingFailuresByStage,
            invocationCounts: [:]
        ))
    }

    func errnoCode(stage: String, path _: String) -> Int32? {
        state.withLock { state in
            state.invocationCounts[stage, default: 0] += 1
            if var failures = state.failuresByStage[stage], !failures.isEmpty {
                let failure = failures.removeFirst()
                state.failuresByStage[stage] = failures
                return failure
            }
            return state.repeatingFailuresByStage[stage]
        }
    }

    func invocationCount(for stage: String) -> Int {
        state.withLock { $0.invocationCounts[stage, default: 0] }
    }

    func replaceFailures(_ failures: [Int32], for stage: String) {
        state.withLock { $0.failuresByStage[stage] = failures }
    }
}

import Darwin
import Dispatch
import Foundation
import os

@testable import CmuxControlSocket

/// Records a connection delivered directly from the listener queue. The test
/// deliberately waits synchronously on the main actor, so delivery cannot
/// depend on a main-actor or cooperative-executor task getting a turn.
final class DirectConnectionHandlerProbe: @unchecked Sendable {
    private let handled = DispatchSemaphore(value: 0)
    private let state = OSAllocatedUnfairLock(initialState: 0)

    func handle(_ connection: ControlConnection) {
        close(connection.socket)
        state.withLock { $0 += 1 }
        handled.signal()
    }

    func wait(timeout: TimeInterval) -> Bool {
        handled.wait(timeout: .now() + timeout) == .success
    }

    var invocationCount: Int {
        state.withLock { $0 }
    }
}

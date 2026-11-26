import Foundation
import os
@testable import CmuxHomeCore

/// One fake `cmux.wire/1` socket: the test pushes owner frames and reads
/// what the client sent; `drop` ends it as a lost connection would.
final class FakeWireSocket: HomeWireSocket {
    let request: URLRequest

    private struct State {
        var inbound: [String] = []
        var waiter: CheckedContinuation<String, any Error>?
        var ended = false
        var sent: [String] = []
        var closeCode: Int?
        var upgradeStatus: Int?
    }

    // A test fake: the lock guards the frame queue shared by the client's receive and the test's push.
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(request: URLRequest) {
        self.request = request
    }

    /// Frames the client sent, parsed.
    var sent: [HomeWireJSON] { state.withLockUnchecked { $0.sent }.compactMap(HomeWireJSON.parse) }
    var isEnded: Bool { state.withLockUnchecked { $0.ended } }

    /// The owner sends `frame`.
    func push(_ frame: HomeWireJSON) {
        let waiter = state.withLockUnchecked { state -> CheckedContinuation<String, any Error>? in
            guard !state.ended else { return nil }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.inbound.append(frame.text)
            return nil
        }
        waiter?.resume(returning: frame.text)
    }

    /// The connection ends (with the owner's close code, or an upgrade refusal).
    func drop(code: Int? = nil, upgradeStatus: Int? = nil) {
        let waiter = state.withLockUnchecked { state -> CheckedContinuation<String, any Error>? in
            guard !state.ended else { return nil }
            state.ended = true
            state.closeCode = code
            state.upgradeStatus = upgradeStatus
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(throwing: URLError(.networkConnectionLost))
    }

    func send(_ text: String) async throws {
        let ended = state.withLockUnchecked { state -> Bool in
            guard !state.ended else { return true }
            state.sent.append(text)
            return false
        }
        if ended { throw URLError(.networkConnectionLost) }
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            let ready = state.withLockUnchecked { state -> Result<String, any Error>? in
                if !state.inbound.isEmpty { return .success(state.inbound.removeFirst()) }
                if state.ended { return .failure(URLError(.networkConnectionLost)) }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func close() {
        drop(code: state.withLockUnchecked { $0.closeCode })
    }

    var closeCode: Int? { state.withLockUnchecked { $0.closeCode } }
    var upgradeStatus: Int? { state.withLockUnchecked { $0.upgradeStatus } }

    func ping() async -> Bool { !isEnded }
}

import Foundation
import os
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// A ``HomeWireSocket`` over one `URLSessionWebSocketTask`.
final class URLSessionHomeWireSocket: HomeWireSocket {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        // wakeup-allow: bounded each pass awaits one WebSocket message; a text or data frame or an error ends it
        while true {
            switch try await task.receive() {
            case .string(let text): return text
            case .data(let data): return String(decoding: data, as: UTF8.self)
            @unknown default: continue
            }
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }

    var closeCode: Int? {
        let code = task.closeCode
        return code == .invalid ? nil : code.rawValue
    }

    var upgradeStatus: Int? {
        guard let status = (task.response as? HTTPURLResponse)?.statusCode, status != 101 else { return nil }
        return status
    }

    func ping() async -> Bool {
        // A synchronous one-shot resume guard: URLSession may call the pong
        // handler more than once while the socket tears down (lock carve-out).
        let claimed = OSAllocatedUnfairLock(initialState: false)
        // A pong handler URLSession drops uncalled (abandoned) is a failed ping.
        let answered = try? await withOnceContinuation { (continuation: OnceContinuation<Bool, OnceContinuationError>) in
            task.sendPing { error in
                let first = claimed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: error == nil) }
            }
        }
        return answered ?? false
    }
}

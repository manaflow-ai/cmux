import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import struct CmuxSafeConcurrency.Mutex
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
        let claim = PongClaim()
        // A pong handler URLSession drops uncalled (abandoned) is a failed ping.
        let answered = try? await withOnceContinuation { (continuation: OnceContinuation<Bool, OnceContinuationError>) in
            task.sendPing { error in
                if claim.isFirst() { continuation.resume(returning: error == nil) }
            }
        }
        return answered ?? false
    }
}

/// True for the first pong handler call of one ping only.
private final class PongClaim: Sendable {
    private let claimed = Mutex(false)

    func isFirst() -> Bool {
        claimed.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
    }
}

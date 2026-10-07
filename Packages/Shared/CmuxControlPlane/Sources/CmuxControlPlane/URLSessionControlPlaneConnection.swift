import Foundation

/// One `URLSessionWebSocketTask`; a failed receive reports the close code.
final class URLSessionControlPlaneConnection: ControlPlaneConnection {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        do {
            switch try await task.receive() {
            case .string(let text): return text
            case .data(let data): return String(decoding: data, as: UTF8.self)
            @unknown default: return ""
            }
        } catch {
            let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
            throw ControlPlaneCloseError(code: task.closeCode.rawValue, reason: reason)
        }
    }

    func close(code: Int) async {
        task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: nil)
    }
}

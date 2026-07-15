import Foundation
@testable import CmuxBrowser

actor NavigationTestCDPTransport: CDPWebSocketTransport {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var inboundMessages: [Data] = []
    private var receiveContinuation: CheckedContinuation<Data, any Error>?
    private var sentCommands: [[String: CDPJSONValue]] = []

    nonisolated func resume() {}

    func send(_ data: Data) async throws {
        let command = try decoder.decode([String: CDPJSONValue].self, from: data)
        sentCommands.append(command)
        guard let requestID = command["id"]?.intValue else { return }

        let result: CDPJSONValue
        if command["method"]?.stringValue == "Page.getFrameTree" {
            result = .object([
                "frameTree": .object([
                    "frame": .object(["id": .string("main-frame")]),
                ]),
            ])
        } else {
            result = .object([:])
        }
        try enqueue(encoder.encode([
            "id": CDPJSONValue.number(Double(requestID)),
            "result": result,
        ]))
    }

    func receive() async throws -> Data {
        if !inboundMessages.isEmpty {
            return inboundMessages.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            receiveContinuation = continuation
        }
    }

    nonisolated func cancel() {
        Task {
            await finish()
        }
    }

    func commands() -> [[String: CDPJSONValue]] {
        sentCommands
    }

    private func enqueue(_ data: Data) {
        if let receiveContinuation {
            self.receiveContinuation = nil
            receiveContinuation.resume(returning: data)
        } else {
            inboundMessages.append(data)
        }
    }

    private func finish() {
        receiveContinuation?.resume(throwing: CancellationError())
        receiveContinuation = nil
    }
}

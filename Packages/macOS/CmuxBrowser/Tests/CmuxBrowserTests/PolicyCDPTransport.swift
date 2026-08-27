import Foundation
@testable import CmuxBrowser

/// Responds to policy-interceptor setup commands and records the wire calls.
actor PolicyCDPTransport: ChromiumCDPTransport {
    private let stream: AsyncStream<Result<Data, CDPError>>
    private let continuation: AsyncStream<Result<Data, CDPError>>.Continuation
    private var sent: [CDPValue] = []

    init() {
        let pair = AsyncStream<Result<Data, CDPError>>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func connect() async throws {}

    nonisolated func messages() -> AsyncStream<Result<Data, CDPError>> { stream }

    func send(_ data: Data) async throws {
        let value = try JSONDecoder().decode(CDPValue.self, from: data)
        sent.append(value)
        guard case .object(let object) = value,
              let id = object["id"]?.doubleValue else { return }
        let result: CDPValue = object["method"]?.stringValue == "Page.getFrameTree"
            ? .object([
                "frameTree": .object([
                    "frame": .object(["id": .string("main-frame")])
                ])
            ])
            : .object([:])
        let response = try JSONEncoder().encode(CDPValue.object([
            "id": .number(id),
            "result": result,
        ]))
        continuation.yield(.success(response))
    }

    func close() { continuation.finish() }

    func emit(_ data: Data) {
        continuation.yield(.success(data))
    }

    func commands() -> [CDPValue] { sent }
}

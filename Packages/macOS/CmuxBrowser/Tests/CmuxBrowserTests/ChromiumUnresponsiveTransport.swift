import Foundation
@testable import CmuxBrowser

actor ChromiumUnresponsiveTransport: ChromiumCDPTransport {
    private let stream: AsyncStream<Result<Data, CDPError>>
    private let continuation: AsyncStream<Result<Data, CDPError>>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func connect() {}
    nonisolated func messages() -> AsyncStream<Result<Data, CDPError>> { stream }
    func send(_ data: Data) {}
    func close() { continuation.finish() }
}

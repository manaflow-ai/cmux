import Foundation
@testable import CmuxBrowser

final class NoResponseCDPWebSocketTransport: CDPWebSocketTransport {
    func resume() {}

    func send(_: Data) async throws {}

    func receive() async throws -> Data {
        try await ContinuousClock().sleep(for: .seconds(60))
        return Data()
    }

    func cancel() {}
}

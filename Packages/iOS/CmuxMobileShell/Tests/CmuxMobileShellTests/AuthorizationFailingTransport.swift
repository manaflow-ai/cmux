import CmuxMobileRPC
import Foundation

actor AuthorizationFailingTransport: CmxByteTransport {
    func connect() async throws {
        throw MobileShellConnectionError.authorizationFailed("Authorization failed")
    }

    func receive() async throws -> Data? {
        nil
    }

    func send(_ data: Data) async throws {
        _ = data
    }

    func close() async {}
}

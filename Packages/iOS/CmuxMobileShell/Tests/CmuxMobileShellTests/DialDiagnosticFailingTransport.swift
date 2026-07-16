import CMUXMobileCore
import CmuxMobileTransport
import Foundation

actor DialDiagnosticFailingTransport: CmxByteTransport {
    func connect() async throws {
        throw CmxNetworkByteTransportError.connectionFailed("sensitive transport detail", .hostUnreachable)
    }

    func receive() async throws -> Data? { nil }
    func send(_ data: Data) async throws {}
    func close() async {}
}

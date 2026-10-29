import Foundation
import Testing
@testable import CmuxTerminalClientKit

struct TerminalClientTests {
    @Test func trustedCarrierRequiresWireGuardTunnel() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: TerminalClientError.self) {
            _ = try TerminalClient.connect(
                route: "ws://[fd00::10]:1337/v1/link",
                stateDirectory: directory,
                deviceName: "iPhone",
                trustedCarrier: true,
                wireGuard: nil
            )
        }
    }
}

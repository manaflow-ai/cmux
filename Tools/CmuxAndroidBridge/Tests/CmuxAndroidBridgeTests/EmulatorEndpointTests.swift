@testable import CmuxAndroidBridge
import Foundation
import Testing

@Suite
struct EmulatorEndpointTests {
    @Test
    func findsExactAVDAndConsolePortWithoutTruncatingTokenPadding() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
        avd.name=Pixel_9
        port.serial=5556
        grpc.port=8556
        grpc.token=token=with=padding
        """.write(to: directory.appendingPathComponent("pid_42.ini"), atomically: true, encoding: .utf8)

        let endpoint = try EmulatorEndpointLocator(
            runningDirectoryURL: directory,
            processMatches: { _, _, _, _ in true }
        )
            .endpoint(avdName: "Pixel_9", serial: "emulator-5556")

        #expect(endpoint == EmulatorEndpoint(port: 8556, bearerToken: "token=with=padding"))
    }

    @Test
    func rejectsAReusedOrMismatchedSerial() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
        avd.name=Pixel_9
        port.serial=5554
        grpc.port=8554
        grpc.token=secret
        """.write(to: directory.appendingPathComponent("pid_42.ini"), atomically: true, encoding: .utf8)

        #expect(throws: BridgeFailure.self) {
            _ = try EmulatorEndpointLocator(
                runningDirectoryURL: directory,
                processMatches: { _, _, _, _ in true }
            )
                .endpoint(avdName: "Pixel_9", serial: "emulator-5556")
        }
    }

    @Test
    func ignoresStaleDiscoveryFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
        avd.name=Pixel_9
        port.serial=5554
        grpc.port=8554
        grpc.token=stale
        """.write(to: directory.appendingPathComponent("pid_42.ini"), atomically: true, encoding: .utf8)

        #expect(throws: BridgeFailure.self) {
            _ = try EmulatorEndpointLocator(
                runningDirectoryURL: directory,
                processMatches: { _, _, _, _ in false }
            )
                .endpoint(avdName: "Pixel_9", serial: "emulator-5554")
        }
    }
}

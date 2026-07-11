@testable import CmuxAndroidEmulatorUI
import Foundation
import Testing

@Suite
struct AndroidEmulatorBridgeLocatorTests {
    @Test
    func runtimeSocketFitsTheMacOSUnixPathLimit() {
        let socketPath = AndroidEmulatorBridgeRuntimePath
            .directoryURL(identifier: UUID())
            .appendingPathComponent("bridge.sock").path

        #expect(socketPath.utf8CString.count <= 104)
    }

    @Test
    func usesExplicitExecutableOverride() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("bridge")
        FileManager.default.createFile(atPath: executable.path, contents: Data("bridge".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let located = try AndroidEmulatorBridgeLocator(
            environment: ["CMUX_ANDROID_BRIDGE_PATH": executable.path],
            homeDirectory: directory
        ).executableURL()

        #expect(located == executable)
    }

    @Test
    func rejectsNonExecutableOverride() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: (any Error).self) {
            try AndroidEmulatorBridgeLocator(
                environment: ["CMUX_ANDROID_BRIDGE_PATH": missing.path, "PATH": ""],
                homeDirectory: missing
            ).executableURL()
        }
    }
}

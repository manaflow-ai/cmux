import Foundation
import Testing
@testable import CmuxRemoteSession

extension RemoteSubprocessTests {
@Suite("Remote host-wide port scan script")
struct RemoteAllPortsScanScriptTests {
    @Test("A failed scanner preserves partial positive observations without claiming completeness")
    func failedScannerEmitsPartialPositives() throws {
        let result = try runFakeSS(exitStatus: 1)

        #expect(result.status == 0)
        #expect(result.output.split(whereSeparator: \.isNewline).contains("4200"))
        #expect(result.output.contains(RemoteSessionCoordinator.remotePortScanCompleteMarker) == false)
    }

    @Test("A successful scanner emits the authoritative completion marker")
    func successfulScannerEmitsCompletionMarker() throws {
        let result = try runFakeSS(exitStatus: 0)

        #expect(result.status == 0)
        #expect(result.output.split(whereSeparator: \.isNewline).contains("4200"))
        #expect(result.output.contains(RemoteSessionCoordinator.remotePortScanCompleteMarker))
    }

    @Test("Scanner stderr is not parsed as port evidence")
    func scannerStderrIsNotPortEvidence() throws {
        let result = try runFakeSS(exitStatus: 1, emitsPortShapedStandardError: true)

        #expect(result.status == 0)
        #expect(result.output.split(whereSeparator: \.isNewline).contains("4200"))
        #expect(result.output.split(whereSeparator: \.isNewline).contains("4300") == false)
        #expect(result.output.contains(RemoteSessionCoordinator.remotePortScanCompleteMarker) == false)
    }

    private func runFakeSS(
        exitStatus: Int32,
        emitsPortShapedStandardError: Bool = false
    ) throws -> (status: Int32, output: String) {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fakeSS = temporaryDirectory.appendingPathComponent("ss")
        let standardErrorCommand = emitsPortShapedStandardError
            ? "printf '%s\\n' 'scanner diagnostic row 127.0.0.1:4300' >&2"
            : ":"
        try """
        #!/bin/sh
        printf '%s\\n' 'LISTEN 0 128 127.0.0.1:4200 0.0.0.0:*'
        \(standardErrorCommand)
        exit \(exitStatus)
        """.write(to: fakeSS, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSS.path)

        let process = Process()
        let standardOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            RemoteSessionCoordinator.remoteAllPortsScanScript(excluding: []),
        ]
        process.environment = ["PATH": "\(temporaryDirectory.path):/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let output = String(
            decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        return (process.terminationStatus, output)
    }
}
}

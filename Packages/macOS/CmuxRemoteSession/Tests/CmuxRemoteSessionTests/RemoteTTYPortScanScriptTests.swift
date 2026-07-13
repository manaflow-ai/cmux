import Foundation
import Testing
@testable import CmuxRemoteSession

@Suite("Remote TTY port scan script", .serialized)
struct RemoteTTYPortScanScriptTests {
    @Test("A pid-less row for a published port withholds completeness")
    func protectedPIDLessRowIsIncomplete() throws {
        let result = try runFakeSS(exitStatus: 0, protecting: [4200])

        #expect(result.status == 0)
        #expect(result.output.split(whereSeparator: \.isNewline).contains("ttys010\t4300"))
        #expect(result.output.contains(RemoteSessionCoordinator.remotePortScanCompleteMarker) == false)
    }

    @Test("An unrelated pid-less row does not poison a complete TTY scan")
    func unrelatedPIDLessRowAllowsCompleteness() throws {
        let result = try runFakeSS(exitStatus: 0, protecting: [])

        #expect(result.status == 0)
        #expect(result.output.split(whereSeparator: \.isNewline).contains("ttys010\t4300"))
        #expect(result.output.contains(RemoteSessionCoordinator.remotePortScanCompleteMarker))
    }

    @Test("A failed ss scan still emits positive evidence without completeness")
    func failedSSScanPreservesPositives() throws {
        let result = try runFakeSS(exitStatus: 1, protecting: [])

        #expect(result.status == 0)
        #expect(result.output.split(whereSeparator: \.isNewline).contains("ttys010\t4300"))
        #expect(result.output.contains(RemoteSessionCoordinator.remotePortScanCompleteMarker) == false)
    }

    @Test("A successful lsof fallback supersedes an unusable ss scan")
    func successfulLsofFallbackIsComplete() throws {
        let result = try runFailedSSWithSuccessfulLsof()

        #expect(result.status == 0)
        #expect(result.output.split(whereSeparator: \.isNewline).contains("ttys010\t4200"))
        #expect(result.output.contains(RemoteSessionCoordinator.remotePortScanCompleteMarker))
    }

    private func runFakeSS(exitStatus: Int32, protecting ports: Set<Int>) throws -> (status: Int32, output: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeExecutable(
            directory.appendingPathComponent("ss"),
            body: """
            #!/bin/sh
            printf '%s\\n' 'LISTEN 0 128 127.0.0.1:4300 users:(("node",pid=123,fd=4))'
            printf '%s\\n' 'LISTEN 0 128 127.0.0.1:4200 0.0.0.0:*'
            exit \(exitStatus)
            """
        )
        try writeExecutable(
            directory.appendingPathComponent("readlink"),
            body: """
            #!/bin/sh
            printf '%s\\n' '/dev/ttys010'
            """
        )

        return try runGeneratedScript(in: directory, protecting: ports)
    }

    private func runFailedSSWithSuccessfulLsof() throws -> (status: Int32, output: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeExecutable(
            directory.appendingPathComponent("ss"),
            body: """
            #!/bin/sh
            exit 1
            """
        )
        try writeExecutable(
            directory.appendingPathComponent("ps"),
            body: """
            #!/bin/sh
            printf '%s\\n' '123 ttys010'
            """
        )
        try writeExecutable(
            directory.appendingPathComponent("lsof"),
            body: """
            #!/bin/sh
            printf '%s\\n' 'p123' 'n*:4200'
            """
        )

        return try runGeneratedScript(in: directory, protecting: [])
    }

    private func runGeneratedScript(
        in directory: URL,
        protecting ports: Set<Int>
    ) throws -> (status: Int32, output: String) {
        let generatedScript = RemoteSessionCoordinator.remotePortScanScript(
            ttyNames: ["ttys010"],
            excluding: [],
            protecting: ports
        )
        let testableScript = generatedScript.replacingOccurrences(
            of: "[ -d /proc ]",
            with: "[ 1 -eq 1 ]"
        )

        remoteSubprocessTestLock.lock()
        defer { remoteSubprocessTestLock.unlock() }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", testableScript]
        process.environment = ["PATH": "\(directory.path):/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func writeExecutable(_ url: URL, body: String) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

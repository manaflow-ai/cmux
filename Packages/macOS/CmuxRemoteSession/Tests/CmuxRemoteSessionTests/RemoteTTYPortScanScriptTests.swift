import Foundation
import Testing
@testable import CmuxRemoteSession

extension RemoteSubprocessTests {
@Suite("Remote TTY port scan script")
struct RemoteTTYPortScanScriptTests {
    @Test("A pid-less row for a published port withholds completeness")
    func protectedPIDLessRowIsIncomplete() throws {
        let result = try runFakeSS(exitStatus: 0, protecting: [4200])

        #expect(result.status == 0)
        #expect(result.output.split(whereSeparator: \.isNewline).contains("ttys010\t4300"))
        #expect(hasCompletionMarker(result.output, for: "ttys010") == false)
    }

    @Test("An unrelated pid-less row does not poison a complete TTY scan")
    func unrelatedPIDLessRowAllowsCompleteness() throws {
        let result = try runFakeSS(exitStatus: 0, protecting: [])

        #expect(result.status == 0)
        #expect(result.output.split(whereSeparator: \.isNewline).contains("ttys010\t4300"))
        #expect(hasCompletionMarker(result.output, for: "ttys010"))
    }

    @Test("A failed ss scan still emits positive evidence without completeness")
    func failedSSScanPreservesPositives() throws {
        let result = try runFakeSS(exitStatus: 1, protecting: [])

        #expect(result.status == 0)
        #expect(result.output.split(whereSeparator: \.isNewline).contains("ttys010\t4300"))
        #expect(hasCompletionMarker(result.output, for: "ttys010") == false)
    }

    @Test("A successful lsof fallback supersedes an unusable ss scan")
    func successfulLsofFallbackIsComplete() throws {
        let result = try runFailedSSWithSuccessfulLsof()

        #expect(result.status == 0)
        #expect(result.output.split(whereSeparator: \.isNewline).contains("ttys010\t4200"))
        #expect(hasCompletionMarker(result.output, for: "ttys010"))
    }

    @Test("An empty ps no-match result completes every tracked TTY")
    func emptyPSNoMatchIsComplete() throws {
        let result = try runFailedSSWithLsofFallback(
            psBody: "exit 1",
            lsofBody: "exit 99"
        )

        #expect(result.status == 0)
        #expect(hasCompletionMarker(result.output, for: "ttys010"))
        #expect(hasCompletionMarker(result.output, for: "ttys011"))
    }

    @Test("A failed ps result with output or diagnostics stays incomplete")
    func failedPSWithEvidenceIsIncomplete() throws {
        let partial = try runFailedSSWithLsofFallback(
            psBody: "printf '%s\\n' '123 ttys010'; exit 1",
            lsofBody: "exit 99"
        )
        let diagnostic = try runFailedSSWithLsofFallback(
            psBody: "printf '%s\\n' 'inspection failed' >&2; exit 1",
            lsofBody: "exit 99"
        )

        #expect(hasCompletionMarker(partial.output, for: "ttys010") == false)
        #expect(hasCompletionMarker(diagnostic.output, for: "ttys010") == false)
    }

    @Test("Readlink failures withhold each protected owner's marker but preserve a healthy TTY")
    func readlinkFailuresAreScopedToProtectedTTYs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeExecutable(
            directory.appendingPathComponent("ss"),
            body: """
            #!/bin/sh
            printf '%s\\n' 'LISTEN 0 128 127.0.0.1:4300 users:(("node",pid=123,fd=4))'
            printf '%s\\n' 'LISTEN 0 128 127.0.0.1:4200 users:(("node",pid=456,fd=4))'
            printf '%s\\n' 'LISTEN 0 128 127.0.0.1:5173 users:(("node",pid=789,fd=4))'
            """
        )
        try writeExecutable(
            directory.appendingPathComponent("readlink"),
            body: """
            #!/bin/sh
            case "$1" in
              */123/fd/0) printf '%s\\n' '/dev/ttys010' ;;
              *) exit 1 ;;
            esac
            """
        )

        let result = try runGeneratedScript(
            in: directory,
            ttyNames: ["ttys010", "ttys011", "ttys012"],
            protecting: ["ttys011": [4200], "ttys012": [5173]]
        )

        #expect(result.status == 0)
        #expect(result.output.split(whereSeparator: \.isNewline).contains("ttys010\t4300"))
        #expect(hasCompletionMarker(result.output, for: "ttys010"))
        #expect(hasCompletionMarker(result.output, for: "ttys011") == false)
        #expect(hasCompletionMarker(result.output, for: "ttys012") == false)
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

        return try runGeneratedScript(
            in: directory,
            ttyNames: ["ttys010"],
            protecting: ["ttys010": ports]
        )
    }

    private func runFailedSSWithSuccessfulLsof() throws -> (status: Int32, output: String) {
        try runFailedSSWithLsofFallback(
            psBody: "printf '%s\\n' '123 ttys010'",
            lsofBody: "printf '%s\\n' 'p123' 'n*:4200'"
        )
    }

    private func runFailedSSWithLsofFallback(
        psBody: String,
        lsofBody: String
    ) throws -> (status: Int32, output: String) {
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
            \(psBody)
            """
        )
        try writeExecutable(
            directory.appendingPathComponent("lsof"),
            body: """
            #!/bin/sh
            \(lsofBody)
            """
        )

        return try runGeneratedScript(
            in: directory,
            ttyNames: ["ttys010", "ttys011"],
            protecting: [:]
        )
    }

    private func runGeneratedScript(
        in directory: URL,
        ttyNames: [String],
        protecting portsByTTY: [String: Set<Int>]
    ) throws -> (status: Int32, output: String) {
        let generatedScript = RemoteSessionCoordinator.remotePortScanScript(
            ttyNames: ttyNames,
            excluding: [],
            protecting: portsByTTY
        )
        let testableScript = generatedScript.replacingOccurrences(
            of: "[ -d /proc ]",
            with: "[ 1 -eq 1 ]"
        )

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

    private func completionMarker(for ttyName: String) -> String {
        "\(RemoteSessionCoordinator.remoteTTYPortScanCompleteMarker)\t\(ttyName)"
    }

    private func hasCompletionMarker(_ output: String, for ttyName: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains(Substring(completionMarker(for: ttyName)))
    }

    private func writeExecutable(_ url: URL, body: String) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
}

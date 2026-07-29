import Foundation
import Testing

@testable import CmuxFoundation

@Suite(.serialized)
struct SSHForegroundAuthenticationRetryPolicyTests {
    @Test func mapsBootTimeTransportFailureToRetryableStatus() throws {
        let result = try run(
            "printf '%s\\n' 'ssh: connect to host example.test port 22: Network is unreachable' >&2; exit 255"
        )

        #expect(result.status == 254)
        #expect(result.stderr.contains("Network is unreachable"))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func preservesPermanentAuthenticationFailure() throws {
        let result = try run(
            "printf '%s\\n' 'user@example.test: Permission denied (publickey,password).' >&2; exit 255"
        )

        #expect(result.status == 255)
        #expect(result.stderr.contains("Permission denied"))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func distinguishesUnclassifiedFailureFromPermanentFailure() throws {
        let result = try run("exit 255")

        #expect(result.status == 252)
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func permanentFailureTakesPrecedenceOverEarlierTransportDiagnostic() throws {
        let result = try run(
            """
            printf '%s\\n' 'debug1: connect to address 2001:db8::1 port 22: Network is unreachable' >&2
            printf '%s\\n' 'user@example.test: Permission denied (publickey,password).' >&2
            exit 255
            """
        )

        #expect(result.status == 255)
        #expect(result.stderr.contains("Network is unreachable"))
        #expect(result.stderr.contains("Permission denied"))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func mapsTemporaryDNSResolutionFailureToRetryableStatus() throws {
        let result = try run(
            """
            printf '%s\\n' \
              'ssh: Could not resolve hostname example.test: Temporary failure in name resolution' >&2
            exit 255
            """
        )

        #expect(result.status == 254)
        #expect(result.stderr.contains("Temporary failure in name resolution"))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func keepsDiagnosticStateBoundedWhileCommandIsRunning() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-policy-bounds-\(UUID().uuidString)", isDirectory: true)
        let readyFile = temporaryDirectory.appendingPathComponent("producer-ready")
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            SSHForegroundAuthenticationRetryPolicy().classifyingTransientFailure(
                in: """
                /usr/bin/yes 'diagnostic padding' | /usr/bin/head -c 1048576 >&2
                : > "$CMUX_TEST_READY_FILE"
                /bin/sleep 1
                exit 255
                """
            ),
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = temporaryDirectory.path
        environment["CMUX_TEST_READY_FILE"] = readyFile.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        let deadline = Date.now.addingTimeInterval(5)
        while !fileManager.fileExists(atPath: readyFile.path), process.isRunning, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(fileManager.fileExists(atPath: readyFile.path))

        let diagnosticFiles = try fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: []
        ).filter { $0 != readyFile }
        let largestDiagnosticFile = try diagnosticFiles
            .map { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
            .max() ?? 0

        #expect(
            largestDiagnosticFile <= 64,
            "Foreground authentication must not retain unbounded remote-controlled stderr"
        )
        process.waitUntilExit()
        #expect(process.terminationStatus == 252)
    }

    private func run(_ command: String) throws -> (
        status: Int32,
        stderr: String,
        temporaryFiles: [String]
    ) {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-policy-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            SSHForegroundAuthenticationRetryPolicy().classifyingTransientFailure(in: command),
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = temporaryDirectory.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        try process.run()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let temporaryFiles = try fileManager.contentsOfDirectory(atPath: temporaryDirectory.path)
        return (
            process.terminationStatus,
            String(data: stderrData, encoding: .utf8) ?? "",
            temporaryFiles
        )
    }
}

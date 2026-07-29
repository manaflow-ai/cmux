import Foundation
import Testing
@testable import CmuxRemoteSession

// Ported from the app-target WorkspaceRemotePlatformProbeTests (#6056) when
// the remote bootstrap probe was lifted into CmuxRemoteSession. The probe must
// stay BusyBox-portable (OpenWrt builds without FEATURE_TR_CLASSES corrupt
// `tr '[:upper:]' '[:lower:]'`), must sanitize the version segment before it is
// interpolated into remote shell, and must strip internal markers from the
// stdout used in user-facing error detail.
//
// Each script case spawns a real `Process` with `Pipe`s, so this suite lives
// under the shared serialized subprocess parent.
extension RemoteSubprocessTests {
@Suite("RemotePlatformProbeScript")
struct RemotePlatformProbeScriptTests {
    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    @Test("Probe works when tr lacks character classes (OpenWrt BusyBox)")
    func probeScriptWorksWhenTrLacksCharacterClasses() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-remote-platform-probe-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let daemonURL = home
            .appendingPathComponent(".cmux/bin/cmuxd-remote/test-version/linux-amd64", isDirectory: true)
            .appendingPathComponent("cmuxd-remote", isDirectory: false)
        try fileManager.createDirectory(at: daemonURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeExecutableShellFile(
            at: daemonURL,
            body: """
            #!/bin/sh
            exit 0
            """
        )
        try Self.writeExecutableShellFile(
            at: bin.appendingPathComponent("uname"),
            body: """
            #!/bin/sh
            case "${1:-}" in
              -s) printf '%s\\n' Linux ;;
              -m) printf '%s\\n' x86_64 ;;
              *) exit 1 ;;
            esac
            """
        )
        try Self.writeExecutableShellFile(
            at: bin.appendingPathComponent("tr"),
            body: """
            #!/bin/sh
            # OpenWrt BusyBox without FEATURE_TR_CLASSES maps these literal
            # argument bytes positionally, so Linux becomes Linlx.
            if [ "$#" -eq 2 ] && [ "$1" = '[:upper:]' ] && [ "$2" = '[:lower:]' ]; then
              awk -v from="$1" -v to="$2" '
                BEGIN {
                  for (i = 1; i <= length(from); i++) {
                    map[substr(from, i, 1)] = substr(to, i, 1)
                  }
                }
                {
                  if (NR > 1) {
                    printf "\\n"
                  }
                  output = ""
                  for (i = 1; i <= length($0); i++) {
                    ch = substr($0, i, 1)
                    output = output ((ch in map) ? map[ch] : ch)
                  }
                  printf "%s", output
                }
              '
              exit 0
            fi
            exec /usr/bin/tr "$@"
            """
        )

        let result = try Self.runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)",
                "PATH=\(bin.path):/usr/bin:/bin",
                "/bin/sh",
                "-c",
                RemoteSessionCoordinator.remotePlatformProbeScript(version: "test-version"),
            ]
        )

        let outputComment = Comment(rawValue: result.stdout + result.stderr)
        let stdoutComment = Comment(rawValue: result.stdout)
        #expect(result.status == 0, outputComment)
        #expect(
            result.stdout.contains("\(RemoteSessionCoordinator.remotePlatformProbeOSMarker)Linux"),
            stdoutComment
        )
        #expect(
            result.stdout.contains("\(RemoteSessionCoordinator.remotePlatformProbeArchMarker)x86_64"),
            stdoutComment
        )
        #expect(
            result.stdout.contains("\(RemoteSessionCoordinator.remotePlatformProbeExistsMarker)yes"),
            stdoutComment
        )
    }

    @Test("Probe sanitizes the version before shell interpolation")
    func probeScriptSanitizesVersionBeforeShellInterpolation() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-remote-platform-probe-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let daemonURL = home
            .appendingPathComponent(".cmux/bin/cmuxd-remote/dev/linux-amd64", isDirectory: true)
            .appendingPathComponent("cmuxd-remote", isDirectory: false)
        try fileManager.createDirectory(at: daemonURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeExecutableShellFile(
            at: daemonURL,
            body: """
            #!/bin/sh
            exit 0
            """
        )
        try Self.writeExecutableShellFile(
            at: bin.appendingPathComponent("uname"),
            body: """
            #!/bin/sh
            case "${1:-}" in
              -s) printf '%s\\n' Linux ;;
              -m) printf '%s\\n' x86_64 ;;
              *) exit 1 ;;
            esac
            """
        )

        let result = try Self.runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)",
                "PATH=\(bin.path):/usr/bin:/bin",
                "/bin/sh",
                "-c",
                RemoteSessionCoordinator.remotePlatformProbeScript(
                    version: #""; printf "__CMUX_INJECTED__\n"; #"#
                ),
            ]
        )

        let outputComment = Comment(rawValue: result.stdout + result.stderr)
        let stdoutComment = Comment(rawValue: result.stdout)
        #expect(result.status == 0, outputComment)
        #expect(!result.stdout.contains("__CMUX_INJECTED__"), stdoutComment)
        #expect(
            result.stdout.contains("\(RemoteSessionCoordinator.remotePlatformProbeExistsMarker)yes"),
            stdoutComment
        )
    }

    @Test("User-facing stdout omits internal probe markers")
    func userFacingStdoutOmitsInternalProbeMarkers() {
        let stdout = """
        \(RemoteSessionCoordinator.remotePlatformProbeHomeMarker)/root
        \(RemoteSessionCoordinator.remotePlatformProbeOSMarker)Linux
        actual failure detail
        \(RemoteSessionCoordinator.remotePlatformProbeArchMarker)x86_64
        """

        #expect(RemoteSessionCoordinator.remotePlatformProbeUserFacingStdout(stdout) == "actual failure detail")
    }

    @Test("armv7 maps to arm")
    func armv7MapsToArm() {
        #expect(RemoteSessionCoordinator.mapUnameArch("armv7") == "arm")
        #expect(RemoteSessionCoordinator.mapUnameArch("armv7l") == "arm")
    }

    private static func writeExecutableShellFile(at url: URL, body: String) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func runProcess(executablePath: String, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
}

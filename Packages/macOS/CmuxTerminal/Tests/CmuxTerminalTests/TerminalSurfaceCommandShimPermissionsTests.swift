import Foundation
import Testing
@testable import CmuxTerminal

@Suite("Terminal surface command-shim permissions")
struct TerminalSurfaceCommandShimPermissionsTests {
    @Test("Install hardens group-writable managed directories")
    func installHardensGroupWritableManagedDirectories() throws {
        let fileManager = FileManager.default
        let root = URL.temporaryDirectory.appending(
            path: "TerminalSurfaceCommandShimPermissionsTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let temporaryDirectory = root.appending(path: "tmp", directoryHint: .isDirectory)
        let parentDirectory = temporaryDirectory.appending(
            path: "cmux-cli-shims",
            directoryHint: .isDirectory
        )
        let surfaceId = UUID()
        let shimDirectory = parentDirectory.appending(path: surfaceId.uuidString, directoryHint: .isDirectory)
        let wrapper = root.appending(path: "cmux-claude-wrapper", directoryHint: .notDirectory)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
        for directory in [parentDirectory, shimDirectory] {
            try fileManager.setAttributes([.posixPermissions: 0o775], ofItemAtPath: directory.path)
        }
        try "#!/bin/sh\nexit 0\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)

        let shim = try #require(
            TerminalSurface.installClaudeCommandShimIfPossible(
                wrapperURL: wrapper,
                surfaceId: surfaceId,
                temporaryDirectory: temporaryDirectory,
                fileManager: fileManager
            )
        )
        #expect(shim.directoryPath == shimDirectory.path)
        for directory in [parentDirectory, shimDirectory] {
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            #expect(permissions.uint16Value == 0o700)
        }
    }

    @Test("Install creates a Pi shim beside the Claude shim")
    func installCreatesPiShim() throws {
        let fileManager = FileManager.default
        let root = URL.temporaryDirectory.appending(
            path: "TerminalSurfacePiCommandShimTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let temporaryDirectory = root.appending(path: "tmp", directoryHint: .isDirectory)
        let wrapperDirectory = root.appending(path: "bin", directoryHint: .isDirectory)
        let claudeWrapper = wrapperDirectory.appending(
            path: "cmux-claude-wrapper",
            directoryHint: .notDirectory
        )
        let piWrapper = wrapperDirectory.appending(
            path: "cmux-pi-wrapper",
            directoryHint: .notDirectory
        )
        let log = root.appending(path: "pi.log", directoryHint: .notDirectory)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: wrapperDirectory, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: claudeWrapper, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        printf '%s\n' "${CMUX_PI_WRAPPER_SHIM:-}" > "$CMUX_TEST_LOG"
        printf '%s\n' "$*" >> "$CMUX_TEST_LOG"
        """.write(to: piWrapper, atomically: true, encoding: .utf8)
        for wrapper in [claudeWrapper, piWrapper] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        }

        let claudeShim = try #require(
            TerminalSurface.installClaudeCommandShimIfPossible(
                wrapperURL: claudeWrapper,
                surfaceId: UUID(),
                temporaryDirectory: temporaryDirectory,
                fileManager: fileManager
            )
        )
        let piShim = URL(fileURLWithPath: claudeShim.directoryPath, isDirectory: true)
            .appending(path: "pi", directoryHint: .notDirectory)
        #expect(fileManager.isExecutableFile(atPath: piShim.path))

        let process = Process()
        process.executableURL = piShim
        process.arguments = ["hello", "two words"]
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "CMUX_TEST_LOG": log.path,
        ]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        let output = try String(contentsOf: log, encoding: .utf8)
        #expect(output == "\(piShim.path)\nhello two words\n")
    }
}

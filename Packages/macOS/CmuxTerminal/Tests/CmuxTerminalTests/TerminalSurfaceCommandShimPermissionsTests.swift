import Foundation
import Testing
@testable import CmuxTerminal

@Suite("Terminal surface command shims")
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
        let staleShim = shimDirectory.appending(path: "stale-agent", directoryHint: .notDirectory)
        let wrapperDirectory = root.appending(path: "bin", directoryHint: .isDirectory)
        let wrapper = wrapperDirectory.appending(path: "cmux-claude-wrapper", directoryHint: .notDirectory)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: wrapperDirectory, withIntermediateDirectories: true)
        for directory in [parentDirectory, shimDirectory] {
            try fileManager.setAttributes([.posixPermissions: 0o775], ofItemAtPath: directory.path)
        }
        try "stale\n".write(to: staleShim, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)

        let shim = try #require(
            TerminalSurface.installAgentCommandShimsIfPossible(
                wrapperDirectoryURL: wrapperDirectory,
                surfaceId: surfaceId,
                temporaryDirectory: temporaryDirectory,
                fileManager: fileManager
            )
        )
        #expect(shim.directoryPath == shimDirectory.path)
        let claudeShim = try #require(shim.shim(named: "claude"))
        #expect(!fileManager.fileExists(atPath: staleShim.path))
        #expect(fileManager.isExecutableFile(atPath: claudeShim.executablePath))
        for directory in [parentDirectory, shimDirectory] {
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            #expect(permissions.uint16Value == 0o700)
        }
    }

    @Test("Fallback preserves literal glob characters in PATH entries")
    func fallbackPreservesLiteralGlobCharactersInPathEntries() throws {
        let fileManager = FileManager.default
        let root = URL.temporaryDirectory.appending(
            path: "TerminalSurfaceCommandShimPathTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let temporaryDirectory = root.appending(path: "tmp", directoryHint: .isDirectory)
        let wrapperDirectory = root.appending(path: "bin", directoryHint: .isDirectory)
        let wrapper = wrapperDirectory.appending(path: "cmux-claude-wrapper", directoryHint: .notDirectory)
        let literalPathDirectory = root.appending(path: "literal-[z]", directoryHint: .isDirectory)
        let globMatchDirectory = root.appending(path: "literal-z", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: root) }

        for directory in [wrapperDirectory, literalPathDirectory, globMatchDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "#!/bin/sh\nexit 0\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)

        let shims = try #require(
            TerminalSurface.installAgentCommandShimsIfPossible(
                wrapperDirectoryURL: wrapperDirectory,
                surfaceId: UUID(),
                temporaryDirectory: temporaryDirectory,
                fileManager: fileManager
            )
        )
        let shim = try #require(shims.shim(named: "claude"))

        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: wrapper.path)
        let expectedExecutable = literalPathDirectory.appending(path: "claude", directoryHint: .notDirectory)
        let globMatchedExecutable = globMatchDirectory.appending(path: "claude", directoryHint: .notDirectory)
        try "#!/bin/sh\nprintf 'literal-path\\n'\n".write(
            to: expectedExecutable,
            atomically: true,
            encoding: .utf8
        )
        try "#!/bin/sh\nprintf 'glob-expanded-path\\n'\n".write(
            to: globMatchedExecutable,
            atomically: true,
            encoding: .utf8
        )
        for executable in [expectedExecutable, globMatchedExecutable] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shim.executablePath)
        process.currentDirectoryURL = root
        process.environment = [
            "PATH": "\(shim.directoryPath):\(literalPathDirectory.path):/usr/bin:/bin",
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(String(data: data, encoding: .utf8) == "literal-path\n")
    }
}

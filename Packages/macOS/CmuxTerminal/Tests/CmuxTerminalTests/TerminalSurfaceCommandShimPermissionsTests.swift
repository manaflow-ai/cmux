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
        let wrapperDirectory = root.appending(path: "bin", directoryHint: .isDirectory)
        let wrapper = wrapperDirectory.appending(path: "cmux-claude-wrapper", directoryHint: .notDirectory)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: wrapperDirectory, withIntermediateDirectories: true)
        for directory in [parentDirectory, shimDirectory] {
            try fileManager.setAttributes([.posixPermissions: 0o775], ofItemAtPath: directory.path)
        }
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
        for directory in [parentDirectory, shimDirectory] {
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            #expect(permissions.uint16Value == 0o700)
        }
    }
}

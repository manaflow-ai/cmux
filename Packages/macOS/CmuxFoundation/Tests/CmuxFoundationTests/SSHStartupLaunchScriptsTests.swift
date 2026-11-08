import Foundation
import Testing
@testable import CmuxFoundation

/// Fails every permission change, as if another process read the launcher
/// before a create-then-chmod writer could restrict it.
private final class PermissionChangeFailingFileManager: FileManager {
    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

@Suite("SSH startup launch scripts")
struct SSHStartupLaunchScriptsTests {
    private let credentialBody = "cmux_ssh_password_b64='c2VjcmV0'\nexec ssh cmux@example.test"

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-launch-scripts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func entries(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    @Test("A launcher whose terminal never starts leaves no credential on disk")
    func unlaunchedScriptIsRemoved() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launchScripts = SSHStartupLaunchScripts(directory: directory)

        _ = try launchScripts.write(scriptBody: credentialBody, remoteRelayPort: 0)
        // The workspace was reused, its startup command was replaced, or it
        // failed to be created or configured, so nothing runs the launcher.
        launchScripts.removeUnlaunched()

        #expect(try entries(in: directory).isEmpty)
    }

    @Test("A launcher handed to a terminal stays until it runs and removes itself")
    func handedOffScriptSurvives() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launchScripts = SSHStartupLaunchScripts(directory: directory)

        let script = try launchScripts.write(scriptBody: credentialBody, remoteRelayPort: 0)
        launchScripts.handOff()
        launchScripts.removeUnlaunched()

        #expect(FileManager.default.fileExists(atPath: script.path))
    }

    @Test("A launcher is private to its owner")
    func scriptIsOwnerOnly() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launchScripts = SSHStartupLaunchScripts(directory: directory)

        let script = try launchScripts.write(scriptBody: credentialBody, remoteRelayPort: 0)
        let permissions = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber

        #expect(permissions?.intValue == 0o700)
        launchScripts.removeUnlaunched()
    }

    @Test("A launcher is owner-only from the moment it exists")
    func scriptIsCreatedOwnerOnly() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launchScripts = SSHStartupLaunchScripts(
            directory: directory,
            fileManager: PermissionChangeFailingFileManager()
        )

        // Without a later permission change, the file keeps its creation mode.
        let script = try? launchScripts.write(scriptBody: credentialBody, remoteRelayPort: 0)
        defer { launchScripts.removeUnlaunched() }
        let created = try entries(in: directory)
        #expect(created.count == 1)
        for name in created {
            let path = directory.appendingPathComponent(name).path
            let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o700, "\(name) mode \(String(permissions?.intValue ?? 0, radix: 8))")
        }
        let written = try #require(script)
        #expect(try String(contentsOf: written, encoding: .utf8) == "#!/bin/sh\n\(credentialBody)\n")
    }

    @Test("A launcher is never written through a file already at its path")
    func preplacedSymlinkIsNotFollowed() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        try Data("original".utf8).write(to: target)
        let link = directory.appendingPathComponent("cmux-ssh-startup-0-fixed.sh")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let launchScripts = SSHStartupLaunchScripts(
            directory: directory,
            fileManager: FileManager(),
            scriptName: { _ in "cmux-ssh-startup-0-fixed.sh" }
        )

        #expect(throws: (any Error).self) {
            try launchScripts.write(scriptBody: credentialBody, remoteRelayPort: 0)
        }
        // The file at the path is not the owner's, so cleanup leaves it.
        launchScripts.removeUnlaunched()

        #expect(try String(contentsOf: target, encoding: .utf8) == "original")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    }
}

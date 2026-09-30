import CmuxFoundation
import Foundation
import Testing

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
}

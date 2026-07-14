import Foundation
import Testing

@testable import CmuxGit

@Suite struct GitDiffServicePathDeadlineTests {
    @Test func repositoryRootPreservesTrailingWhitespace() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-git-whitespace-parent-\(UUID().uuidString)")
        let repo = parent.appendingPathComponent("repo ")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try initializeRepository(at: repo)

        let root = try #require(GitDiffService().repositoryRoot(for: repo.path))

        #expect(root.hasSuffix("/repo "))
        #expect(URL(fileURLWithPath: root).standardizedFileURL == repo.standardizedFileURL)
    }

    @Test func gitProcessLaunchesOutsideRepositoryAndPassesExactDirectoryWithDashC() throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-git-safe-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try initializeRepository(at: repo)
        let marker = repo.appendingPathComponent("process-pwd.txt")
        let checkingGit = repo.appendingPathComponent("checking-launch-git.sh")
        let script = """
        #!/bin/sh
        /bin/pwd > \(marker.path.debugDescription)
        if [ "$1" != "-C" ] || [ "$2" != \(repo.path.debugDescription) ]; then exit 92; fi
        printf '%s\\n' "$2"
        """
        try Data(script.utf8).write(to: checkingGit)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: checkingGit.path
        )

        let root = GitDiffService(gitExecutableURL: checkingGit).repositoryRoot(for: repo.path)
        let processDirectory = try String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .newlines)

        #expect(root == repo.path)
        #expect(processDirectory == "/")
    }

    private func initializeRepository(at repo: URL) throws {
        for arguments in [
            ["init", "--quiet"],
            ["config", "user.email", "tests@cmux.dev"],
            ["config", "user.name", "cmux tests"],
            ["commit", "--allow-empty", "--quiet", "-m", "init"],
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = repo
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }
    }
}

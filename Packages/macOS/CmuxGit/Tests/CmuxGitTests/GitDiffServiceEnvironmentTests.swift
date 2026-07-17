import Foundation
import Testing

@testable import CmuxGit

@Suite struct GitDiffServiceEnvironmentTests {
    @Test func ambientPathspecModesAreScrubbedBeforeExactFileDiff() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let fileName = "file[1].txt"
        let fileURL = repo.appendingPathComponent(fileName)
        try Data("original\n".utf8).write(to: fileURL)
        try runTestGit(in: repo, ["add", "--", fileName])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add exact file"])
        try Data("changed\n".utf8).write(to: fileURL)

        let guardedGit = repo.appendingPathComponent("guarded-git.sh")
        try Data("""
        #!/bin/sh
        if [ "${GIT_LITERAL_PATHSPECS+x}" = x ] || [ "${GIT_ICASE_PATHSPECS+x}" = x ]; then
          exit 91
        fi
        exec /usr/bin/git "$@"
        """.utf8).write(to: guardedGit)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: guardedGit.path
        )
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_LITERAL_PATHSPECS"] = "1"
        environment["GIT_ICASE_PATHSPECS"] = "1"

        let service = GitDiffService(
            gitExecutableURL: guardedGit,
            environment: environment
        )
        let diff = try #require(service.fileDiff(repoRoot: repo.path, path: fileName))

        #expect(diff.unifiedDiff.contains("+changed"))
    }

    private func makeTempRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-git-diff-environment-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for arguments in [
            ["init", "--quiet"],
            ["config", "user.email", "tests@cmux.dev"],
            ["config", "user.name", "cmux tests"],
            ["commit", "--allow-empty", "--quiet", "-m", "init"],
        ] {
            try runTestGit(in: root, arguments)
        }
        return root
    }

    private func runTestGit(in root: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }
}

import CMUXRepoDetection
import Foundation
import Testing

@Suite("Repo launch detection")
struct RepoLaunchDetectionTests {
    @Test("Detects package script using the repository package manager")
    func detectsPackageScript() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try """
        {
          "scripts": {
            "start": "vite",
            "use": "cmux-use"
          }
        }
        """.write(to: directory.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        _ = FileManager.default.createFile(
            atPath: directory.appendingPathComponent("pnpm-lock.yaml").path,
            contents: Data(),
            attributes: nil
        )

        #expect(CMUXRepoDetection.packageJSONLaunchCommand(in: directory) == CMUXDetectedLaunchCommand(
            command: "pnpm run use",
            source: "package.json:scripts.use"
        ))
    }

    @Test("Chooses package manager from lockfiles")
    func choosesPackageManager() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(CMUXRepoDetection.packageManagerCommand(in: directory) == "npm")

        _ = FileManager.default.createFile(
            atPath: directory.appendingPathComponent("yarn.lock").path,
            contents: Data(),
            attributes: nil
        )
        #expect(CMUXRepoDetection.packageManagerCommand(in: directory) == "yarn")

        try FileManager.default.removeItem(at: directory.appendingPathComponent("yarn.lock"))
        _ = FileManager.default.createFile(
            atPath: directory.appendingPathComponent("bun.lock").path,
            contents: Data(),
            attributes: nil
        )
        #expect(CMUXRepoDetection.packageManagerCommand(in: directory) == "bun")
    }

    @Test("Makefile launch detection skips bare make and checks alternate filename")
    func makefileLaunchSkipsBareMake() throws {
        let bareMakefileDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bareMakefileDirectory) }

        try """
        all:
        \tcc main.c
        """.write(to: bareMakefileDirectory.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)

        #expect(CMUXRepoDetection.makefileLaunchCommand(in: bareMakefileDirectory) == nil)

        let lowercaseMakefileDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: lowercaseMakefileDirectory) }

        try """
        clean:
        \trm -rf build

        run:
        \t./extension
        """.write(to: lowercaseMakefileDirectory.appendingPathComponent("makefile"), atomically: true, encoding: .utf8)

        #expect(CMUXRepoDetection.makefileLaunchCommand(in: lowercaseMakefileDirectory) == CMUXDetectedLaunchCommand(
            command: "make run",
            source: "makefile:run"
        ))
    }

    @Test("Makefile target parser ignores recipes and comments")
    func makefileTargetParserIgnoresRecipesAndComments() {
        let contents = """
        # start:
        all:
        \tstart:

        start:
        \t./start
        """

        #expect(CMUXRepoDetection.makefile(contents, hasTarget: "start"))
        #expect(!CMUXRepoDetection.makefile("# run:\n\tuse:\n", hasTarget: "run"))
        #expect(!CMUXRepoDetection.makefile("all:\n\tuse:\n", hasTarget: "use"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CMUXRepoDetectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

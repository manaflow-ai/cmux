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

    @Test("Generated manifest hints sanitize package-derived fields")
    func generatedManifestHintsSanitizePackageFields() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try """
        {
          "name": "@scope/cmux\\u0007market",
          "version": "1.2.\\u001b3",
          "scripts": {
            "start": "vite",
            "postinstall": "node setup.js"
          }
        }
        """.write(to: directory.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

        let hints = CMUXRepoDetection.generatedManifestHints(in: directory)
        let disallowed = CharacterSet.controlCharacters.union(.illegalCharacters)

        #expect(hints.displayName == "cmuxmarket")
        #expect(hints.version == "1.2.3")
        #expect(hints.displayName?.unicodeScalars.allSatisfy { !disallowed.contains($0) } == true)
        #expect(hints.version?.unicodeScalars.allSatisfy { !disallowed.contains($0) } == true)
        #expect(hints.installCommand == "npm run postinstall")
        #expect(hints.launchCommand == CMUXDetectedLaunchCommand(
            command: "npm run start",
            source: "package.json:scripts.start"
        ))
        #expect(hints.permissions.contains("shell:npm"))
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
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try """
        all:
        \tcc main.c
        """.write(to: directory.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        try """
        clean:
        \trm -rf build

        run:
        \t./extension
        """.write(to: directory.appendingPathComponent("makefile"), atomically: true, encoding: .utf8)

        #expect(CMUXRepoDetection.makefileLaunchCommand(in: directory) == CMUXDetectedLaunchCommand(
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

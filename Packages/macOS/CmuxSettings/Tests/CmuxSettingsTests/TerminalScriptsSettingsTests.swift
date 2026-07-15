import Testing
import CmuxSettings

@Suite struct TerminalScriptsSettingsTests {
    @Test func savedCommandLibraryRoundTripsThroughJSON() throws {
        let original = SavedTerminalCommandLibrary(commands: [
            SavedTerminalCommand(id: "build", name: "Build", command: "pnpm install\npnpm build")
        ])
        let decoded = SavedTerminalCommandLibrary.decodeFromJSON(original.encodeForJSON())

        #expect(decoded == original)
    }

    @Test func savedCommandLibrarySupportsDeterministicCRUD() throws {
        var library = SavedTerminalCommandLibrary()

        let savedBuild = library.save(SavedTerminalCommand(id: "build", name: "Build", command: "pnpm build"))
        let savedTest = library.save(SavedTerminalCommand(id: "test", name: "Test", command: "pnpm test"))
        let savedDuplicate = library.save(SavedTerminalCommand(id: "other", name: "build", command: "make"))
        let updatedBuild = library.save(SavedTerminalCommand(id: "build", name: "Build All", command: "pnpm -r build"))

        #expect(savedBuild)
        #expect(savedTest)
        #expect(!savedDuplicate)
        #expect(updatedBuild)
        #expect(library.commands.map(\.id) == ["build", "test"])
        #expect(library.command(named: "BUILD ALL")?.command == "pnpm -r build")

        library.remove(id: "test")
        #expect(library.commands.map(\.id) == ["build"])
    }

    @Test func repositoryPreferenceRoundTripsThroughJSON() throws {
        let original = RepositoryScriptPreference(
            repositoryID: "repo-id",
            repositoryRoot: "/tmp/repo",
            setup: "pnpm install",
            archive: "pnpm clean",
            overridesProjectScripts: true,
            promptDismissed: true
        )
        let decoded = RepositoryScriptPreference.decodeFromJSON(original.encodeForJSON())

        #expect(decoded == original)
    }
}

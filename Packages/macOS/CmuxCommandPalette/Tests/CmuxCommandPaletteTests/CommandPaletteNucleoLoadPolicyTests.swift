@testable import CmuxCommandPalette
import Testing

@Suite struct CommandPaletteNucleoLoadPolicyTests {
    @Test func backendOnlyOwnershipRejectsDeveloperPathsInDebugBuilds() {
        #expect(
            !CommandPaletteNucleoSearchLibrary.permitsDeveloperLibraryPaths(
                runtimeOwnership: "backend-only",
                debugBuild: true
            )
        )
    }

    @Test func releaseBuildsRejectDeveloperPathsForEveryOwnershipMode() {
        #expect(
            !CommandPaletteNucleoSearchLibrary.permitsDeveloperLibraryPaths(
                runtimeOwnership: nil,
                debugBuild: false
            )
        )
        #expect(
            !CommandPaletteNucleoSearchLibrary.permitsDeveloperLibraryPaths(
                runtimeOwnership: "legacy",
                debugBuild: false
            )
        )
    }

    @Test func onlyNonAttestedDebugBuildsRetainDeveloperPaths() {
        #expect(
            CommandPaletteNucleoSearchLibrary.permitsDeveloperLibraryPaths(
                runtimeOwnership: nil,
                debugBuild: true
            )
        )
        #expect(
            CommandPaletteNucleoSearchLibrary.permitsDeveloperLibraryPaths(
                runtimeOwnership: "legacy",
                debugBuild: true
            )
        )
    }
}

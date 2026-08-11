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

    @Test func developerOverridePrecedesBundledLibraryWhenPermitted() {
        #expect(
            CommandPaletteNucleoSearchLibrary.prioritizedLibraryPaths(
                environmentPath: "/tmp/developer/libnucleo.dylib",
                bundledLibraryPath: "/Applications/cmux.app/Contents/Frameworks/libnucleo.dylib",
                permitsDeveloperLibraryPaths: true
            ) == [
                "/tmp/developer/libnucleo.dylib",
                "/Applications/cmux.app/Contents/Frameworks/libnucleo.dylib",
            ]
        )
        #expect(
            CommandPaletteNucleoSearchLibrary.prioritizedLibraryPaths(
                environmentPath: "/tmp/developer/libnucleo.dylib",
                bundledLibraryPath: "/Applications/cmux.app/Contents/Frameworks/libnucleo.dylib",
                permitsDeveloperLibraryPaths: false
            ) == [
                "/Applications/cmux.app/Contents/Frameworks/libnucleo.dylib"
            ]
        )
    }
}

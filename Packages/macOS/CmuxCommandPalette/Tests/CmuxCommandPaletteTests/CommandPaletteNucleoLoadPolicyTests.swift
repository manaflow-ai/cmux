@testable import CmuxCommandPalette
import Testing

@Suite struct CommandPaletteNucleoLoadPolicyTests {
    @Test func backendOnlyOwnershipRejectsDeveloperPathsInDebugBuilds() {
        #expect(
            !CommandPaletteNucleoLibraryPathPolicy(
                environmentPath: nil,
                bundledLibraryPath: nil,
                runtimeOwnership: "backend-only",
                debugBuild: true
            ).permitsDeveloperPaths
        )
    }

    @Test func releaseBuildsRejectDeveloperPathsForEveryOwnershipMode() {
        #expect(
            !CommandPaletteNucleoLibraryPathPolicy(
                environmentPath: nil,
                bundledLibraryPath: nil,
                runtimeOwnership: nil,
                debugBuild: false
            ).permitsDeveloperPaths
        )
        #expect(
            !CommandPaletteNucleoLibraryPathPolicy(
                environmentPath: nil,
                bundledLibraryPath: nil,
                runtimeOwnership: "legacy",
                debugBuild: false
            ).permitsDeveloperPaths
        )
    }

    @Test func onlyNonAttestedDebugBuildsRetainDeveloperPaths() {
        #expect(
            CommandPaletteNucleoLibraryPathPolicy(
                environmentPath: nil,
                bundledLibraryPath: nil,
                runtimeOwnership: nil,
                debugBuild: true
            ).permitsDeveloperPaths
        )
        #expect(
            CommandPaletteNucleoLibraryPathPolicy(
                environmentPath: nil,
                bundledLibraryPath: nil,
                runtimeOwnership: "legacy",
                debugBuild: true
            ).permitsDeveloperPaths
        )
    }

    @Test func developerOverridePrecedesBundledLibraryWhenPermitted() {
        #expect(
            CommandPaletteNucleoLibraryPathPolicy(
                environmentPath: "/tmp/developer/libnucleo.dylib",
                bundledLibraryPath: "/Applications/cmux.app/Contents/Frameworks/libnucleo.dylib",
                runtimeOwnership: nil,
                debugBuild: true
            ).prioritizedLibraryPaths == [
                "/tmp/developer/libnucleo.dylib",
                "/Applications/cmux.app/Contents/Frameworks/libnucleo.dylib",
            ]
        )
        #expect(
            CommandPaletteNucleoLibraryPathPolicy(
                environmentPath: "/tmp/developer/libnucleo.dylib",
                bundledLibraryPath: "/Applications/cmux.app/Contents/Frameworks/libnucleo.dylib",
                runtimeOwnership: "backend-only",
                debugBuild: true
            ).prioritizedLibraryPaths == [
                "/Applications/cmux.app/Contents/Frameworks/libnucleo.dylib"
            ]
        )
    }
}
